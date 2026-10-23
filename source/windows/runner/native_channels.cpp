#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <netioapi.h>

#include "native_channels.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <PortableDeviceApi.h>
#include <PortableDevice.h>
#include <PortableDeviceTypes.h>
#include <bcrypt.h>
#pragma comment(lib, "advapi32.lib")
#include <setupapi.h>
#include <cfgmgr32.h>
#include <winioctl.h>
#include <ntddstor.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

namespace {
using Microsoft::WRL::ComPtr;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
using Result = flutter::MethodResult<Value>;
namespace fs = std::filesystem;
constexpr UINT kReplyMessage = WM_APP + 174;
constexpr uint64_t kFileLimit = 32ULL * 1024 * 1024;
// Ten maximum-size inputs plus one conversion output.
constexpr uint64_t kQuota = 11 * kFileLimit + 4096;  // Bounded ownership-marker overhead.
constexpr wchar_t kMarker[] = L".brizfi_owned";
struct Failure { std::string code; };
[[noreturn]] void Fail(const char* code) { throw Failure{code}; }
void Check(HRESULT hr, const char* code = "usb_transfer_failed") {
  if (FAILED(hr)) Fail(code);
}
std::wstring Lower(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(), towlower);
  return value;
}
std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (size == 0) Fail("invalid_file");
  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), result.data(), size, nullptr, nullptr);
  return result;
}
std::wstring Wide(const std::string& value) {
  if (value.empty()) Fail("invalid_file");
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (size == 0) Fail("invalid_file");
  std::wstring result(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), result.data(), size);
  return result;
}
std::wstring NewUuid() {
  GUID guid{};
  Check(CoCreateGuid(&guid), "storage_unavailable");
  wchar_t text[39]{};
  StringFromGUID2(guid, text, 39);
  return Lower(std::wstring(text + 1, 36));
}
bool IsUuid(const std::wstring& value) {
  if (value.size() != 36) return false;
  for (size_t i = 0; i < value.size(); ++i) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (value[i] != L'-') return false;
    } else if (!((value[i] >= L'0' && value[i] <= L'9') ||
                 (value[i] >= L'a' && value[i] <= L'f'))) return false;
  }
  return true;
}
bool SamePath(const fs::path& a, const fs::path& b) {
  return _wcsicmp(a.c_str(), b.c_str()) == 0;
}
// Reject aliases and reparse points at every component, including ancestors.
// Managed deletion never traverses junctions/symlinks, even inside a UUID folder.
void SafePath(const fs::path& path) {
  if (!path.is_absolute() || path != path.lexically_normal()) Fail("import_failed");
  fs::path part = path.root_path();
  for (const auto& component : path.relative_path()) {
    const auto name = component.wstring();
    if (name.empty() || name.back() == L'.' || name.back() == L' ' ||
        name.find(L':') != std::wstring::npos || name.find(L'\0') != std::wstring::npos) Fail("import_failed");
    part /= component;
    const DWORD attrs = GetFileAttributesW(part.c_str());
    if (attrs == INVALID_FILE_ATTRIBUTES ||
        (attrs & FILE_ATTRIBUTE_REPARSE_POINT)) Fail("import_failed");
  }
}
fs::path ImportRoot() {
  wchar_t temp[MAX_PATH + 1]{};
  const DWORD size = GetTempPathW(MAX_PATH, temp);
  if (size == 0 || size > MAX_PATH) Fail("storage_unavailable");
  const fs::path root = (fs::path(temp) / L"brizfi_imports").lexically_normal();
  SafePath(root.parent_path());
  std::error_code error;
  fs::create_directory(root, error);
  if (error) Fail("storage_unavailable");
  SafePath(root);
  return root;
}
std::string MarkerText(const fs::path& directory) {
  return "brizfi-import-v1\n" + Utf8(directory.filename().wstring()) + "\n";
}
std::vector<fs::path> Children(const fs::path& directory) {
  SafePath(directory);
  std::error_code error;
  fs::directory_iterator iterator(directory, error), end;
  if (error) Fail("storage_unavailable");
  std::vector<fs::path> entries;
  while (iterator != end) {
    if (entries.size() >= 4096) Fail("storage_unavailable");
    entries.push_back(iterator->path());
    iterator.increment(error);
    if (error) Fail("storage_unavailable");
  }
  return entries;
}
uint64_t TreeBytes(const fs::path& path, size_t& visits, size_t depth = 0) {
  if (++visits > 4096 || depth > 32) Fail("storage_unavailable");
  SafePath(path);
  const DWORD attrs = GetFileAttributesW(path.c_str());
  if (attrs & FILE_ATTRIBUTE_DIRECTORY) {
    uint64_t total = 0;
    for (const auto& child : Children(path)) total += TreeBytes(child, visits, depth + 1);
    return total;
  }
  std::error_code error;
  const auto size = fs::file_size(path, error);
  if (error) Fail("storage_unavailable");
  return size;
}
uint64_t TreeBytes(const fs::path& path) { size_t visits = 0; return TreeBytes(path, visits); }
fs::path OwnedDirectory(const fs::path& path) {
  const auto root = ImportRoot();
  SafePath(path);
  const auto directory = SamePath(path.parent_path(), root) ? path : path.parent_path();
  if (!SamePath(directory.parent_path(), root) || !IsUuid(directory.filename().wstring())) {
    Fail("import_failed");
  }
  const auto marker = directory / kMarker;
  SafePath(marker);
  if (TreeBytes(marker) > 128) Fail("import_failed");
  std::ifstream input(marker, std::ios::binary);
  const std::string text((std::istreambuf_iterator<char>(input)), {});
  if (!input || text != MarkerText(directory)) Fail("import_failed");
  return directory;
}
void RemoveOwned(const fs::path& directory) {
  if (!SamePath(OwnedDirectory(directory), directory)) Fail("import_failed");
  TreeBytes(directory);  // Validate the entire bounded tree before any deletion.
  std::error_code error;
  fs::remove_all(directory, error);
  if (error) Fail("storage_unavailable");
}
struct ReaderDevice {
  std::wstring identity;  // Native-only: never expose PnP IDs/serials to Dart or logs.
  std::wstring volume;
  DWORD volume_serial = 0;
  std::string profile;
};
struct State {
  struct Reservation { std::wstring input; uint64_t baseline; };
  HWND window;
  std::atomic<bool> stopped{false}, busy{false}, cancelled{false};
  std::mutex mutex;
  std::condition_variable wake;
  std::vector<std::function<void()>> replies;
  std::map<std::wstring, Reservation> reservations;
  std::set<std::wstring> live;
  std::map<int32_t, ReaderDevice> devices;
  int32_t next_device = 1;
  explicit State(HWND handle) : window(handle) {}
  void Active() const { if (cancelled || stopped) Fail("usb_cancelled"); }
  void Post(std::function<void()> reply) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!stopped) {
      replies.push_back(std::move(reply));
      PostMessageW(window, kReplyMessage, 0, 0);
    }
  }
};
uint64_t Accounted(const std::shared_ptr<State>& state) {
  const auto root = ImportRoot();
  uint64_t total = 0;
  size_t visits = 0;
  for (const auto& child : Children(root)) {
    const uint64_t actual = TreeBytes(child, visits);
    auto reservation = state->reservations.find(Lower(child.wstring()));
    total += reservation == state->reservations.end() ? actual :
        std::max(actual, reservation->second.baseline + kFileLimit);
  }
  return total;
}
void ClearExpiredImports(const std::shared_ptr<State>& state) {
  const auto root = ImportRoot();
  TreeBytes(root);  // Validate the complete bounded scan before any deletion.
  for (const auto& directory : Children(root)) {
    const auto key = Lower(directory.wstring());
    if (!IsUuid(directory.filename().wstring()) || state->live.count(key) ||
        state->reservations.count(key)) continue;
    try {
      OwnedDirectory(directory);
      std::error_code error;
      const auto modified = fs::last_write_time(directory / kMarker, error);
      if (!error && fs::file_time_type::clock::now() - modified > std::chrono::hours(24)) {
        RemoveOwned(directory);
      }
    } catch (const Failure&) { /* Never collect unknown or unmarked files. */ }
  }
}
class FileHandle {
 public:
  explicit FileHandle(HANDLE value) : value_(value) {}
  ~FileHandle() { if (value_ != INVALID_HANDLE_VALUE) CloseHandle(value_); }
  HANDLE get() const { return value_; }
 private:
  HANDLE value_;
};
// Validate the opened object, not a path checked before CreateFile. Managed
// sources use DOS final paths; reader destinations use volume GUID final paths.
void ValidateHandlePath(HANDLE handle, const fs::path& path, bool directory,
                        DWORD volume_name, const char* failure) {
  BY_HANDLE_FILE_INFORMATION info{};
  wchar_t final_path[4096]{};
  const DWORD length = GetFinalPathNameByHandleW(handle, final_path, 4096, volume_name);
  if (length == 0 || length >= 4096 || !GetFileInformationByHandle(handle, &info) ||
      (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
      ((info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) != directory) Fail(failure);
  auto expected = Lower(path.wstring());
  if (volume_name == VOLUME_NAME_DOS && expected.rfind(L"\\\\?\\", 0) != 0) {
    if (expected.rfind(L"\\\\", 0) == 0) expected = L"\\\\?\\unc\\" + expected.substr(2);
    else expected = L"\\\\?\\" + expected;
  }
  auto actual = Lower(final_path);
  while (!expected.empty() && expected.back() == L'\\') expected.pop_back();
  while (!actual.empty() && actual.back() == L'\\') actual.pop_back();
  if (actual != expected) Fail(failure);
}
HANDLE ManagedDirectory(const fs::path& path) {
  SafePath(path);
  const HANDLE handle = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ,
      nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (handle == INVALID_HANDLE_VALUE) Fail("usb_invalid_file");
  try { ValidateHandlePath(handle, path, true, VOLUME_NAME_DOS, "usb_invalid_file"); }
  catch (...) { CloseHandle(handle); throw; }
  return handle;
}
std::vector<uint8_t> ReadFileBytes(const fs::path& path, const std::shared_ptr<State>& state,
                                 const char* failure, bool managed = false) {
  SafePath(path);
  // No FILE_SHARE_WRITE or FILE_SHARE_DELETE: hold a stable source snapshot.
  FileHandle input(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (input.get() == INVALID_HANDLE_VALUE) Fail(failure);
  if (managed) ValidateHandlePath(input.get(), path, false, VOLUME_NAME_DOS, failure);
  LARGE_INTEGER size{};
  if (!GetFileSizeEx(input.get(), &size) || size.QuadPart <= 0) Fail(failure);
  if (static_cast<uint64_t>(size.QuadPart) > kFileLimit) {
    Fail(std::string(failure) == "invalid_file" ? "too_large" : failure);
  }
  std::vector<uint8_t> bytes(static_cast<size_t>(size.QuadPart));
  size_t offset = 0;
  while (offset < bytes.size()) {
    state->Active();
    DWORD count = 0;
    const DWORD chunk = static_cast<DWORD>(std::min<size_t>(64 * 1024, bytes.size() - offset));
    if (!ReadFile(input.get(), bytes.data() + offset, chunk, &count, nullptr) || count == 0) Fail(failure);
    offset += count;
  }
  return bytes;
}
std::vector<uint8_t> ReadManagedFileBytes(const fs::path& path, const std::shared_ptr<State>& state) {
  const auto root = ImportRoot();
  if (!SamePath(path.parent_path().parent_path(), root)) Fail("usb_invalid_file");
  // Denying writes prevents reparse-point mutation; denying deletion prevents
  // rename/replacement while the actual source handle is opened and read.
  FileHandle root_handle(ManagedDirectory(root));
  FileHandle directory_handle(ManagedDirectory(path.parent_path()));
  const auto directory = OwnedDirectory(path);
  if (!SamePath(path.parent_path(), directory)) Fail("usb_invalid_file");
  return ReadFileBytes(path, state, "usb_invalid_file", true);
}
std::vector<uint8_t> Sha256(const std::vector<uint8_t>& bytes) {
  std::vector<uint8_t> digest(32);
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) Fail("usb_verification_failed");
  const NTSTATUS status = BCryptHash(algorithm, nullptr, 0,
      const_cast<PUCHAR>(bytes.data()), static_cast<ULONG>(bytes.size()),
      digest.data(), static_cast<ULONG>(digest.size()));
  BCryptCloseAlgorithmProvider(algorithm, 0);
  if (status < 0) Fail("usb_verification_failed");
  return digest;
}
uint16_t Le16(const std::vector<uint8_t>& bytes, size_t offset) {
  if (offset > bytes.size() || bytes.size() - offset < 2) Fail("usb_invalid_file");
  return static_cast<uint16_t>(bytes[offset] | (bytes[offset + 1] << 8));
}
uint32_t Le32(const std::vector<uint8_t>& bytes, size_t offset) {
  if (offset > bytes.size() || bytes.size() - offset < 4) Fail("usb_invalid_file");
  return static_cast<uint32_t>(bytes[offset]) | (static_cast<uint32_t>(bytes[offset + 1]) << 8) |
      (static_cast<uint32_t>(bytes[offset + 2]) << 16) | (static_cast<uint32_t>(bytes[offset + 3]) << 24);
}
uint32_t Be32(const std::vector<uint8_t>& bytes, size_t offset) {
  if (offset > bytes.size() || bytes.size() - offset < 4) Fail("usb_invalid_file");
  return (static_cast<uint32_t>(bytes[offset]) << 24) | (static_cast<uint32_t>(bytes[offset + 1]) << 16) |
      (static_cast<uint32_t>(bytes[offset + 2]) << 8) | static_cast<uint32_t>(bytes[offset + 3]);
}
bool Contains(const std::vector<uint8_t>& bytes, const std::string& text) {
  return std::search(bytes.begin(), bytes.end(), text.begin(), text.end()) != bytes.end();
}
void ValidateEpub(const std::vector<uint8_t>& bytes) {
  // Validate bounded ZIP metadata without extracting files or loading resources.
  // EPUB requires a first, stored mimetype entry with exactly this content.
  const std::string mime = "application/epub+zip";
  if (bytes.size() < 58 || Le32(bytes, 0) != 0x04034b50 || (Le16(bytes, 6) & ~0x800) != 0 ||
      Le16(bytes, 8) != 0 || Le32(bytes, 18) != mime.size() || Le32(bytes, 22) != mime.size() ||
      Le16(bytes, 26) != 8 || Le16(bytes, 28) != 0 ||
      !std::equal(bytes.begin() + 30, bytes.begin() + 38, "mimetype") ||
      !std::equal(mime.begin(), mime.end(), bytes.begin() + 38)) Fail("usb_invalid_file");
  size_t end = bytes.size() - 22;
  const size_t minimum = bytes.size() > 65557 ? bytes.size() - 65557 : 0;
  for (;;) {
    if (Le32(bytes, end) == 0x06054b50 && end + 22 + Le16(bytes, end + 20) == bytes.size()) break;
    if (end == minimum) Fail("usb_invalid_file");
    --end;
  }
  const uint16_t entries = Le16(bytes, end + 10);
  const uint32_t central_size = Le32(bytes, end + 12);
  size_t offset = Le32(bytes, end + 16);
  if (Le16(bytes, end + 4) || Le16(bytes, end + 6) || entries == 0 || entries > 4096 ||
      entries != Le16(bytes, end + 8) || offset > end || central_size != end - offset) Fail("usb_invalid_file");
  bool container = false;
  uint64_t expanded = 0;
  for (uint16_t index = 0; index < entries; ++index) {
    if (offset > end || end - offset < 46 || Le32(bytes, offset) != 0x02014b50) Fail("usb_invalid_file");
    const size_t name_size = Le16(bytes, offset + 28);
    const size_t entry_size = 46 + name_size + Le16(bytes, offset + 30) + Le16(bytes, offset + 32);
    expanded += Le32(bytes, offset + 24);
    if (entry_size > end - offset || Le16(bytes, offset + 34) || (Le16(bytes, offset + 8) & 1) ||
        (Le16(bytes, offset + 10) != 0 && Le16(bytes, offset + 10) != 8) ||
        expanded > 128ULL * 1024 * 1024) Fail("usb_invalid_file");
    const std::string name(bytes.begin() + offset + 46, bytes.begin() + offset + 46 + name_size);
    if (name.empty() || name.front() == '/' || name.find('\\') != std::string::npos ||
        name.find(':') != std::string::npos || name.find('\0') != std::string::npos ||
        name == ".." || name.rfind("../", 0) == 0 || name.find("/../") != std::string::npos ||
        (name.size() >= 3 && name.compare(name.size() - 3, 3, "/..") == 0)) Fail("usb_invalid_file");
    if (name == "META-INF/encryption.xml" || name == "META-INF/rights.xml") Fail("usb_invalid_file");
    if (name == "META-INF/container.xml") container = true;
    const size_t local = Le32(bytes, offset + 42);
    if (local > end || end - local < 30 || Le32(bytes, local) != 0x04034b50 ||
        (Le16(bytes, local + 6) & 1) || Le16(bytes, local + 26) != name_size) Fail("usb_invalid_file");
    if (Le16(bytes, local + 8) != Le16(bytes, offset + 10)) Fail("usb_invalid_file");
    const size_t data_offset = local + 30 + name_size + Le16(bytes, local + 28);
    const uint32_t compressed = Le32(bytes, offset + 20);
    if (data_offset > end || compressed > end - data_offset ||
        !std::equal(name.begin(), name.end(), bytes.begin() + local + 30)) Fail("usb_invalid_file");
    offset += entry_size;
  }
  if (offset != end || !container) Fail("usb_invalid_file");
}
void ValidateBook(const std::vector<uint8_t>& bytes, const std::wstring& extension) {
  if (bytes.empty()) Fail("usb_invalid_file");
  if (extension == L".epub") { ValidateEpub(bytes); return; }
  if (extension == L".azw3" || extension == L".mobi") {
    if (bytes.size() < 86 || !std::equal(bytes.begin() + 60, bytes.begin() + 68, "BOOKMOBI")) Fail("usb_invalid_file");
    const uint16_t records = static_cast<uint16_t>((bytes[76] << 8) | bytes[77]);
    if (records == 0 || records > 4096 || 78 + static_cast<size_t>(records) * 8 > bytes.size()) Fail("usb_invalid_file");
    const size_t record = Be32(bytes, 78);
    size_t previous = 0;
    for (uint16_t index = 0; index < records; ++index) {
      const size_t current = Be32(bytes, 78 + static_cast<size_t>(index) * 8);
      if (current < 78 + static_cast<size_t>(records) * 8 || current >= bytes.size() ||
          (index != 0 && current <= previous)) Fail("usb_invalid_file");
      previous = current;
    }
    if (record > bytes.size() || bytes.size() - record < 24 ||
        !std::equal(bytes.begin() + record + 16, bytes.begin() + record + 20, "MOBI") ||
        bytes[record + 12] != 0 || bytes[record + 13] != 0) Fail("usb_invalid_file");
    return;
  }
  if (extension == L".pdf") {
    const std::string prefix(bytes.begin(), bytes.begin() + std::min<size_t>(1024, bytes.size()));
    const std::string suffix(bytes.end() - std::min<size_t>(1024, bytes.size()), bytes.end());
    if (prefix.find("%PDF-") == std::string::npos || suffix.find("%%EOF") == std::string::npos ||
        Contains(bytes, "/Encrypt")) Fail("usb_invalid_file");
    return;
  }
  if (extension == L".txt") {
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, reinterpret_cast<const char*>(bytes.data()),
          static_cast<int>(bytes.size()), nullptr, 0) == 0 ||
        std::any_of(bytes.begin(), bytes.end(), [](uint8_t value) {
          return (value < 32 && value != 9 && value != 10 && value != 13) || value == 127;
        })) Fail("usb_invalid_file");
    return;
  }
  Fail("unsupported_format");
}
bool Supports(const ReaderDevice& device, const std::wstring& extension) {
  if (device.profile == "nook") return extension == L".epub" || extension == L".pdf";
  return device.profile == "kindle" && (extension == L".azw3" || extension == L".mobi" ||
      extension == L".pdf" || extension == L".txt");
}
Value PickBooks(const std::shared_ptr<State>& state, bool multiple, bool azw3_only) {
  ComPtr<IFileOpenDialog> dialog;
  Check(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
      IID_PPV_ARGS(&dialog)), "unavailable");
  DWORD options = 0;
  Check(dialog->GetOptions(&options), "unavailable");
  Check(dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST |
      FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR | (multiple ? FOS_ALLOWMULTISELECT : 0)), "unavailable");
  const COMDLG_FILTERSPEC filter[] = {{L"Books (FB2, EPUB, AZW3, MOBI, PDF, TXT)",
      azw3_only ? L"*.azw3" : L"*.fb2;*.epub;*.azw3;*.mobi;*.pdf;*.txt"}};
  Check(dialog->SetFileTypes(1, filter), "unavailable");
  const HRESULT selected = dialog->Show(state->window);
  if (selected == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return Value();
  Check(selected, "import_failed");
  ComPtr<IShellItemArray> items;
  Check(dialog->GetResults(&items), "import_failed");
  DWORD count = 0;
  Check(items->GetCount(&count), "import_failed");
  if (count == 0 || count > 10) Fail("too_many_books");
  // The same serialized worker owns reservations and imports: no startup race,
  // and fresh/live/reserved copies cannot be evicted to make room for a batch.
  ClearExpiredImports(state);
  List paths;
  std::vector<fs::path> created;
  try {
    for (DWORD index = 0; index < count; ++index) {
      state->Active();
      ComPtr<IShellItem> item;
      Check(items->GetItemAt(index, &item), "import_failed");
      PWSTR raw_path = nullptr;
      Check(item->GetDisplayName(SIGDN_FILESYSPATH, &raw_path), "import_failed");
      const fs::path source(raw_path);
      CoTaskMemFree(raw_path);
      const auto extension = Lower(source.extension().wstring());
      if (extension != L".azw3" && (azw3_only || (extension != L".epub" && extension != L".fb2" &&
          extension != L".mobi" && extension != L".pdf" && extension != L".txt"))) {
        Fail("unsupported_format");
      }
      const auto bytes = ReadFileBytes(source, state, "invalid_file");
      if (extension != L".fb2") {
        try { ValidateBook(bytes, extension); } catch (const Failure&) { Fail("invalid_file"); }
      }
      if (Accounted(state) + bytes.size() + 128 > kQuota) Fail("cache_full");
      const auto directory = ImportRoot() / NewUuid();
      if (!CreateDirectoryW(directory.c_str(), nullptr)) Fail("storage_unavailable");
      {
        std::ofstream marker(directory / kMarker, std::ios::binary);
        marker << MarkerText(directory);
        marker.close();
        if (!marker) Fail("storage_unavailable");
      }
      created.push_back(directory);
      const auto target = directory / source.filename();
      FileHandle output(CreateFileW(target.c_str(), GENERIC_WRITE, 0, nullptr,
          CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr));
      if (output.get() == INVALID_HANDLE_VALUE) Fail("storage_unavailable");
      DWORD written = 0;
      if (!WriteFile(output.get(), bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr) ||
          written != bytes.size() || !FlushFileBuffers(output.get())) Fail("storage_unavailable");
      paths.emplace_back(Utf8(target.wstring()));
      state->live.insert(Lower(directory.wstring()));
    }
  } catch (...) {
    for (const auto& directory : created) {
      try { RemoveOwned(directory); } catch (...) { }
      state->live.erase(Lower(directory.wstring()));
    }
    throw;
  }
  return multiple ? Value(paths) : paths.front();
}

ComPtr<IPortableDeviceValues> Values() {
  ComPtr<IPortableDeviceValues> values;
  Check(CoCreateInstance(CLSID_PortableDeviceValues, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&values)));
  return values;
}
std::vector<std::wstring> ConnectedKindles() {
  ComPtr<IPortableDeviceManager> manager;
  Check(CoCreateInstance(CLSID_PortableDeviceManager, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&manager)), "usb_unsupported");
  Check(manager->RefreshDeviceList(), "usb_disconnected");
  DWORD count = 0;
  Check(manager->GetDevices(nullptr, &count), "usb_disconnected");
  if (count > 64) Fail("usb_unsupported");
  std::vector<PWSTR> ids(count, nullptr);
  if (count != 0) Check(manager->GetDevices(ids.data(), &count), "usb_disconnected");
  std::vector<std::wstring> devices;
  for (PWSTR id : ids) {
    if (id) {
      const std::wstring device(id);
      // Only the verified Kindle USB product; Amazon's VID alone also covers
      // non-reader products and must not grant a Kindle format profile.
      const auto normalized = Lower(device);
      if (normalized.find(L"usb#vid_1949&pid_9981#") != std::wstring::npos ||
          normalized.find(L"usb\\vid_1949&pid_9981\\") != std::wstring::npos) devices.push_back(device);
      CoTaskMemFree(id);
    }
  }
  return devices;
}
// Map disk interfaces to their actual USB ancestor, then volumes to disk numbers.
// A label, drive letter, or directory name alone never identifies a NOOK.
std::map<DWORD, std::wstring> NookDisks(const std::shared_ptr<State>& state) {
  const HDEVINFO set = SetupDiGetClassDevsW(&GUID_DEVINTERFACE_DISK, nullptr, nullptr,
      DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
  if (set == INVALID_HANDLE_VALUE) Fail("usb_unsupported");
  struct Close { HDEVINFO value; ~Close() { SetupDiDestroyDeviceInfoList(value); } } close{set};
  std::map<DWORD, std::wstring> disks;
  for (DWORD index = 0; index < 256; ++index) {
    state->Active();
    SP_DEVICE_INTERFACE_DATA interface_data{};
    interface_data.cbSize = sizeof(interface_data);
    if (!SetupDiEnumDeviceInterfaces(set, nullptr, &GUID_DEVINTERFACE_DISK, index, &interface_data)) {
      if (GetLastError() == ERROR_NO_MORE_ITEMS) return disks;
      Fail("usb_unsupported");
    }
    DWORD size = 0;
    SetupDiGetDeviceInterfaceDetailW(set, &interface_data, nullptr, 0, &size, nullptr);
    if (size < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W) || size > 64 * 1024) continue;
    std::vector<uint8_t> buffer(size);
    auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(buffer.data());
    detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);
    SP_DEVINFO_DATA info{};
    info.cbSize = sizeof(info);
    if (!SetupDiGetDeviceInterfaceDetailW(set, &interface_data, detail, size, nullptr, &info)) continue;
    std::wstring usb_identity;
    DEVINST node = info.DevInst;
    for (int depth = 0; depth < 16; ++depth) {
      wchar_t id[MAX_DEVICE_ID_LEN]{};
      if (CM_Get_Device_IDW(node, id, MAX_DEVICE_ID_LEN, 0) != CR_SUCCESS) break;
      const auto normalized = Lower(id);
      if (normalized.rfind(L"usb\\vid_2080&pid_0003\\", 0) == 0) {
        usb_identity = normalized;
        break;
      }
      DEVINST parent = 0;
      if (CM_Get_Parent(&parent, node, 0) != CR_SUCCESS) break;
      node = parent;
    }
    if (usb_identity.empty()) continue;
    FileHandle disk(CreateFileW(detail->DevicePath, 0, FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr, OPEN_EXISTING, 0, nullptr));
    STORAGE_DEVICE_NUMBER number{};
    DWORD received = 0;
    if (disk.get() == INVALID_HANDLE_VALUE || !DeviceIoControl(disk.get(),
        IOCTL_STORAGE_GET_DEVICE_NUMBER, nullptr, 0, &number, sizeof(number), &received, nullptr) ||
        number.DeviceType != FILE_DEVICE_DISK) continue;
    disks.emplace(number.DeviceNumber, usb_identity);
  }
  Fail("usb_unsupported");
}
std::vector<ReaderDevice> ConnectedNooks(const std::shared_ptr<State>& state) {
  const auto disks = NookDisks(state);
  std::vector<ReaderDevice> devices;
  if (disks.empty()) return devices;
  wchar_t volume[MAX_PATH + 1]{};
  const HANDLE search = FindFirstVolumeW(volume, MAX_PATH + 1);
  if (search == INVALID_HANDLE_VALUE) return devices;
  struct Close { HANDLE value; ~Close() { FindVolumeClose(value); } } close{search};
  for (size_t count = 0; count < 256; ++count) {
    state->Active();
    const std::wstring root(volume);
    // Only volume GUID paths are retained. Mount-point/drive-letter replacement
    // cannot redirect a later write to a different volume.
    if (root.rfind(L"\\\\?\\Volume{", 0) == 0 && root.back() == L'\\') {
      FileHandle handle(CreateFileW(root.substr(0, root.size() - 1).c_str(), 0,
          FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr));
      VOLUME_DISK_EXTENTS extents{};
      DWORD received = 0;
      DWORD serial = 0;
      if (handle.get() != INVALID_HANDLE_VALUE && DeviceIoControl(handle.get(),
          IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, nullptr, 0, &extents, sizeof(extents), &received, nullptr) &&
          extents.NumberOfDiskExtents == 1 &&
          GetVolumeInformationW(root.c_str(), nullptr, 0, &serial, nullptr, nullptr, nullptr, 0)) {
        const auto found = disks.find(extents.Extents[0].DiskNumber);
        if (found != disks.end()) {
          const fs::path books = fs::path(root) / L"My Files" / L"Books";
          const DWORD attrs = GetFileAttributesW(books.c_str());
          // Ignore an empty media LUN and unrelated partitions. Sending repeats
          // this check while holding all directories against replacement.
          if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY) &&
              !(attrs & FILE_ATTRIBUTE_REPARSE_POINT)) {
            devices.push_back(ReaderDevice{found->second, root, serial, "nook"});
          }
        }
      }
    }
    if (!FindNextVolumeW(search, volume, MAX_PATH + 1)) {
      if (GetLastError() != ERROR_NO_MORE_FILES) Fail("usb_disconnected");
      return devices;
    }
  }
  Fail("usb_unsupported");
}
bool SameDevice(const ReaderDevice& left, const ReaderDevice& right) {
  return left.identity == right.identity && left.volume == right.volume &&
      left.volume_serial == right.volume_serial && left.profile == right.profile;
}
void RequireNook(const ReaderDevice& expected, const std::shared_ptr<State>& state) {
  const auto connected = ConnectedNooks(state);
  if (std::none_of(connected.begin(), connected.end(), [&](const auto& device) {
        return SameDevice(device, expected);
      })) Fail("usb_disconnected");
}
std::string ReaderIdentityKey(const std::wstring& identity) {
  const auto text = Utf8(Lower(identity));
  const auto digest = Sha256(std::vector<uint8_t>(text.begin(), text.end()));
  std::string key = "usb:";
  constexpr char hex[] = "0123456789abcdef";
  for (const auto byte : digest) { key += hex[byte >> 4]; key += hex[byte & 15]; }
  return key;
}
Value ListDevices(const std::shared_ptr<State>& state) {
  std::vector<ReaderDevice> connected;
  // WPD availability must not hide a mass-storage reader.
  try {
    for (const auto& id : ConnectedKindles()) connected.push_back(ReaderDevice{id, L"", 0, "kindle"});
  } catch (const Failure&) { state->Active(); }
  const auto nooks = ConnectedNooks(state);
  connected.insert(connected.end(), nooks.begin(), nooks.end());
  List devices;
  for (const auto& device : connected) {
    auto found = std::find_if(state->devices.begin(), state->devices.end(),
        [&](const auto& entry) { return SameDevice(entry.second, device); });
    int32_t handle;
    if (found == state->devices.end()) {
      if (state->next_device == INT32_MAX) Fail("usb_unsupported");
      handle = state->next_device++;
      state->devices.emplace(handle, device);
    } else { handle = found->first; }
    const bool nook = device.profile == "nook";
    const List formats = nook ? List{Value("epub"), Value("pdf")} :
        List{Value("azw3"), Value("mobi"), Value("pdf"), Value("txt")};
    devices.emplace_back(Map{{Value("id"), Value(handle)},
        {Value("name"), Value(nook ? "NOOK" : "Kindle")},
        {Value("model"), Value()},
        {Value("identityKey"), Value(ReaderIdentityKey(device.identity))},
        {Value("identityIsUnique"), Value(true)},
        {Value("profile"), Value(device.profile)},
        {Value("transport"), Value(nook ? "massStorage" : "mtp")},
        {Value("formats"), Value(formats)}});
  }
  return Value(devices);
}
ComPtr<IPortableDeviceValues> Properties(IPortableDeviceContent* content, const std::wstring& id) {
  ComPtr<IPortableDeviceProperties> properties;
  Check(content->Properties(&properties));
  ComPtr<IPortableDeviceKeyCollection> keys;
  Check(CoCreateInstance(CLSID_PortableDeviceKeyCollection, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&keys)));
  for (const auto& key : {WPD_OBJECT_NAME, WPD_OBJECT_ORIGINAL_FILE_NAME,
       WPD_OBJECT_CONTENT_TYPE, WPD_OBJECT_PARENT_ID, WPD_OBJECT_SIZE,
       WPD_FUNCTIONAL_OBJECT_CATEGORY}) Check(keys->Add(key));
  ComPtr<IPortableDeviceValues> values;
  Check(properties->GetValues(id.c_str(), keys.Get(), &values));
  return values;
}
std::wstring StringValue(IPortableDeviceValues* values, REFPROPERTYKEY key) {
  PWSTR raw = nullptr;
  if (FAILED(values->GetStringValue(key, &raw))) return {};
  std::wstring result(raw ? raw : L"");
  CoTaskMemFree(raw);
  return result;
}
bool GuidValue(IPortableDeviceValues* values, REFPROPERTYKEY key, REFGUID expected) {
  GUID value{};
  return SUCCEEDED(values->GetGuidValue(key, &value)) && IsEqualGUID(value, expected);
}
std::vector<std::wstring> ObjectIds(IPortableDeviceContent* content, const std::wstring& parent,
                                  const std::shared_ptr<State>& state) {
  ComPtr<IEnumPortableDeviceObjectIDs> enumerator;
  Check(content->EnumObjects(0, parent.c_str(), nullptr, &enumerator));
  std::vector<std::wstring> objects;
  for (;;) {
    state->Active();
    PWSTR id = nullptr;
    DWORD count = 0;
    const HRESULT hr = enumerator->Next(1, &id, &count);
    if (FAILED(hr)) { CoTaskMemFree(id); Check(hr); }
    if (count == 0) { CoTaskMemFree(id); break; }
    objects.emplace_back(id);
    CoTaskMemFree(id);
    if (objects.size() > 4096) Fail("usb_unsupported");
  }
  return objects;
}
std::wstring Documents(IPortableDeviceContent* content, const std::shared_ptr<State>& state) {
  std::wstring found;
  // Only device root -> storage -> documents, never a recursive book walk.
  const auto roots = ObjectIds(content, WPD_DEVICE_OBJECT_ID, state);
  for (const auto& storage : roots) {
    const auto properties = Properties(content, storage);
    if (!GuidValue(properties.Get(), WPD_FUNCTIONAL_OBJECT_CATEGORY, WPD_FUNCTIONAL_CATEGORY_STORAGE)) continue;
    for (const auto& folder : ObjectIds(content, storage, state)) {
      const auto info = Properties(content, folder);
      if (!GuidValue(info.Get(), WPD_OBJECT_CONTENT_TYPE, WPD_CONTENT_TYPE_FOLDER)) continue;
      if (Lower(StringValue(info.Get(), WPD_OBJECT_NAME)) != L"documents" &&
          Lower(StringValue(info.Get(), WPD_OBJECT_ORIGINAL_FILE_NAME)) != L"documents") continue;
      if (!found.empty()) Fail("usb_unsupported");
      found = folder;
    }
  }
  if (found.empty()) Fail("usb_documents_missing");
  return found;
}

// The FTM WPD object can be cancelled from a separate COM-initialized thread.
// Cancellation resolves only after this guard joins and the transfer closes.
class CancelGuard {
 public:
  CancelGuard(std::shared_ptr<State> state, ComPtr<IPortableDevice> device)
      : state_(std::move(state)), thread_([this, device]() mutable {
        const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        std::unique_lock<std::mutex> lock(state_->mutex);
        const bool signaled = state_->wake.wait_for(lock, std::chrono::seconds(120),
            [this]() { return done_ || state_->cancelled || state_->stopped; });
        if (!done_) {
          if (!signaled) state_->cancelled = true;
          lock.unlock();
          device->Cancel();
        }
        device.Reset();
        if (SUCCEEDED(initialized)) CoUninitialize();
      }) {}
  ~CancelGuard() {
    { std::lock_guard<std::mutex> lock(state_->mutex); done_ = true; }
    state_->wake.notify_all();
    thread_.join();
  }
 private:
  std::shared_ptr<State> state_;
  bool done_ = false;
  std::thread thread_;
};

// No directory is created and no reader file is ever deleted. A cancelled
// operation may leave its uniquely named partial file for the user to remove.
HANDLE ReaderDirectory(const fs::path& path) {
  const HANDLE handle = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (handle == INVALID_HANDLE_VALUE) Fail("usb_documents_missing");
  try { ValidateHandlePath(handle, path, true, VOLUME_NAME_GUID, "usb_documents_missing"); }
  catch (...) { CloseHandle(handle); throw; }
  return handle;
}
HANDLE CurrentWorkerHandle() {
  const HANDLE handle = OpenThread(THREAD_TERMINATE, FALSE, GetCurrentThreadId());
  if (handle == nullptr) Fail("usb_unsupported");
  return handle;
}
class DiskCancelGuard {
 public:
  explicit DiskCancelGuard(std::shared_ptr<State> state) : state_(std::move(state)),
      worker_(CurrentWorkerHandle()), thread_([this]() {
        std::unique_lock<std::mutex> lock(state_->mutex);
        const bool signaled = state_->wake.wait_for(lock, std::chrono::seconds(120),
            [this]() { return done_ || state_->cancelled || state_->stopped; });
        if (!done_) {
          if (!signaled) state_->cancelled = true;
          // Repeat until the worker unwinds: covers cancellation between its
          // Active check and the next kernel request. Completion waits for all
          // handles to close; no detached writer can outlive a cancel reply.
          while (!done_) {
            lock.unlock();
            if (worker_ != nullptr) CancelSynchronousIo(worker_);
            lock.lock();
            state_->wake.wait_for(lock, std::chrono::milliseconds(50), [this]() { return done_; });
          }
        }
      }) {}
  ~DiskCancelGuard() {
    { std::lock_guard<std::mutex> lock(state_->mutex); done_ = true; }
    state_->wake.notify_all();
    thread_.join();
    if (worker_ != nullptr) CloseHandle(worker_);
  }
 private:
  std::shared_ptr<State> state_;
  HANDLE worker_;
  bool done_ = false;
  std::thread thread_;
};
Value SendMassStorage(const std::shared_ptr<State>& state, const ReaderDevice& device,
                      const std::vector<uint8_t>& bytes, const std::vector<uint8_t>& digest,
                      const std::wstring& extension, const std::function<void(const std::string&)>& phase) {
  DiskCancelGuard cancellation(state);
  phase("connecting");
  RequireNook(device, state);
  phase("selectingFolder");
  const fs::path root(device.volume);
  // Hold root and both ancestors without write/delete sharing: neither
  // reparse-point mutation nor directory replacement can redirect creation.
  FileHandle root_handle(ReaderDirectory(root));
  FileHandle files_handle(ReaderDirectory(root / L"My Files"));
  const fs::path books = root / L"My Files" / L"Books";
  FileHandle books_handle(ReaderDirectory(books));
  RequireNook(device, state);
  const std::wstring name = L"brizfi-" + NewUuid() + extension;
  const fs::path target = books / name;
  state->Active();
  phase("writing");
  {
    FileHandle output(CreateFileW(target.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH, nullptr));
    if (output.get() == INVALID_HANDLE_VALUE) Fail("usb_transfer_failed");
    for (size_t offset = 0; offset < bytes.size();) {
      state->Active();
      DWORD written = 0;
      const DWORD chunk = static_cast<DWORD>(std::min<size_t>(64 * 1024, bytes.size() - offset));
      if (!WriteFile(output.get(), bytes.data() + offset, chunk, &written, nullptr) ||
          written == 0 || written > chunk) Fail("usb_transfer_failed");
      offset += written;
    }
    state->Active();
    if (!FlushFileBuffers(output.get())) Fail("usb_transfer_failed");
  }
  state->Active();
  RequireNook(device, state);
  phase("verifying");
  // Read every byte from the newly created file, independently of write counts.
  // SafePath is for managed sources; the reader uses held GUID-root directories.
  FileHandle input(CreateFileW(target.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (input.get() == INVALID_HANDLE_VALUE) Fail("usb_verification_failed");
  BY_HANDLE_FILE_INFORMATION info{};
  LARGE_INTEGER size{};
  if (!GetFileInformationByHandle(input.get(), &info) ||
      (info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) ||
      !GetFileSizeEx(input.get(), &size) || size.QuadPart != static_cast<LONGLONG>(bytes.size())) Fail("usb_verification_failed");
  std::vector<uint8_t> actual(bytes.size());
  for (size_t offset = 0; offset < actual.size();) {
    state->Active();
    DWORD count = 0;
    const DWORD chunk = static_cast<DWORD>(std::min<size_t>(64 * 1024, actual.size() - offset));
    if (!ReadFile(input.get(), actual.data() + offset, chunk, &count, nullptr) || count == 0 || count > chunk) Fail("usb_verification_failed");
    offset += count;
  }
  if (Sha256(actual) != digest) Fail("usb_verification_failed");
  state->Active();
  RequireNook(device, state);
  return Value(Map{{Value("bytes"), Value(static_cast<int64_t>(bytes.size()))},
                   {Value("name"), Value(Utf8(name))}});
}

Value SendBook(const std::shared_ptr<State>& state, int32_t device_id, const fs::path& path,
               const std::function<void(const std::string&)>& phase) {
  const auto directory = OwnedDirectory(path);
  if (!SamePath(path.parent_path(), directory) ||
      state->reservations.count(Lower(directory.wstring())) != 0) Fail("usb_invalid_file");
  const auto found = state->devices.find(device_id);
  if (found == state->devices.end()) Fail("usb_disconnected");
  const auto extension = Lower(path.extension().wstring());
  if (!Supports(found->second, extension)) Fail("unsupported_format");
  const auto bytes = ReadManagedFileBytes(path, state);
  ValidateBook(bytes, extension);
  const auto digest = Sha256(bytes);
  if (found->second.profile == "nook") return SendMassStorage(state, found->second, bytes, digest, extension, phase);
  const auto connected = ConnectedKindles();
  if (std::find(connected.begin(), connected.end(), found->second.identity) == connected.end()) Fail("usb_disconnected");
  phase("connecting");
  ComPtr<IPortableDevice> device;
  Check(CoCreateInstance(CLSID_PortableDeviceFTM, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&device)), "usb_unsupported");
  const auto client = Values();
  Check(client->SetStringValue(WPD_CLIENT_NAME, L"BRIZFI"));
  Check(client->SetUnsignedIntegerValue(WPD_CLIENT_MAJOR_VERSION, 1));
  Check(client->SetUnsignedIntegerValue(WPD_CLIENT_MINOR_VERSION, 0));
  Check(client->SetUnsignedIntegerValue(WPD_CLIENT_REVISION, 0));
  Check(client->SetUnsignedIntegerValue(WPD_CLIENT_SECURITY_QUALITY_OF_SERVICE, SECURITY_IMPERSONATION));
  Check(client->SetUnsignedIntegerValue(WPD_CLIENT_DESIRED_ACCESS, GENERIC_READ | GENERIC_WRITE));
  CancelGuard cancellation(state, device);
  Check(device->Open(found->second.identity.c_str(), client.Get()), "usb_busy");
  struct Close { IPortableDevice* value; ~Close() { value->Close(); } } close{device.Get()};
  state->Active();
  ComPtr<IPortableDeviceContent> content;
  Check(device->Content(&content));
  phase("selectingFolder");
  const auto parent = Documents(content.Get(), state);
  const std::wstring name = L"brizfi-" + NewUuid() + extension;
  for (const auto& id : ObjectIds(content.Get(), parent, state)) {
    const auto metadata = Properties(content.Get(), id);
    if (Lower(StringValue(metadata.Get(), WPD_OBJECT_ORIGINAL_FILE_NAME)) == name ||
        Lower(StringValue(metadata.Get(), WPD_OBJECT_NAME)) == name) Fail("usb_transfer_failed");
  }
  state->Active();
  const auto values = Values();
  Check(values->SetStringValue(WPD_OBJECT_PARENT_ID, parent.c_str()));
  Check(values->SetStringValue(WPD_OBJECT_NAME, name.c_str()));
  Check(values->SetStringValue(WPD_OBJECT_ORIGINAL_FILE_NAME, name.c_str()));
  Check(values->SetUnsignedLargeIntegerValue(WPD_OBJECT_SIZE, bytes.size()));
  Check(values->SetGuidValue(WPD_OBJECT_FORMAT, WPD_OBJECT_FORMAT_UNSPECIFIED));
  Check(values->SetGuidValue(WPD_OBJECT_CONTENT_TYPE, WPD_CONTENT_TYPE_GENERIC_FILE));
  ComPtr<IStream> stream;
  DWORD optimal = 0;
  phase("writing");
  Check(content->CreateObjectWithPropertiesAndData(values.Get(), &stream, &optimal, nullptr));
  ComPtr<IPortableDeviceDataStream> data;
  Check(stream.As(&data));
  // Without Commit, Cancel rolls back only this new stream. Never issue Delete:
  // a driver that cannot cancel may leave a uniquely named partial test file.
  struct Rollback {
    IPortableDeviceDataStream* value;
    bool committed = false;
    ~Rollback() { if (!committed) value->Cancel(); }
  } rollback{data.Get()};
  const size_t chunk_size = std::clamp<size_t>(optimal, 4096, 1024 * 1024);
  for (size_t offset = 0; offset < bytes.size();) {
    state->Active();
    const ULONG chunk = static_cast<ULONG>(std::min(chunk_size, bytes.size() - offset));
    ULONG written = 0;
    Check(data->Write(bytes.data() + offset, chunk, &written));
    if (written == 0 || written > chunk) Fail("usb_transfer_failed");
    offset += written;
  }
  state->Active();
  Check(data->Commit(STGC_DEFAULT));
  rollback.committed = true;
  PWSTR raw_id = nullptr;
  Check(data->GetObjectID(&raw_id));
  const std::wstring object_id(raw_id ? raw_id : L"");
  CoTaskMemFree(raw_id);
  if (object_id.empty()) Fail("usb_verification_failed");
  data.Reset();
  stream.Reset();
  state->Active();
  phase("verifying");
  const auto metadata = Properties(content.Get(), object_id);
  ULONGLONG size = 0;
  if (StringValue(metadata.Get(), WPD_OBJECT_PARENT_ID) != parent ||
      StringValue(metadata.Get(), WPD_OBJECT_ORIGINAL_FILE_NAME) != name ||
      FAILED(metadata->GetUnsignedLargeIntegerValue(WPD_OBJECT_SIZE, &size)) || size != bytes.size()) {
    Fail("usb_verification_failed");
  }
  ComPtr<IPortableDeviceResources> resources;
  Check(content->Transfer(&resources));
  ComPtr<IStream> readback;
  optimal = 0;
  Check(resources->GetStream(object_id.c_str(), WPD_RESOURCE_DEFAULT, STGM_READ, &optimal, &readback), "usb_verification_failed");
  std::vector<uint8_t> actual;
  actual.reserve(bytes.size());
  std::vector<uint8_t> buffer(std::clamp<size_t>(optimal, 4096, 1024 * 1024));
  for (;;) {
    state->Active();
    ULONG received = 0;
    Check(readback->Read(buffer.data(), static_cast<ULONG>(buffer.size()), &received), "usb_verification_failed");
    if (received > buffer.size() || actual.size() + received > bytes.size()) Fail("usb_verification_failed");
    if (received == 0) break;
    actual.insert(actual.end(), buffer.begin(), buffer.begin() + received);
  }
  if (actual.size() != bytes.size() || Sha256(actual) != digest) Fail("usb_verification_failed");
  state->Active();
  return Value(Map{{Value("bytes"), Value(static_cast<int64_t>(bytes.size()))},
                   {Value("name"), Value(Utf8(name))}});
}

const Value* Argument(const flutter::MethodCall<Value>& call, const char* key) {
  if (!call.arguments()) return nullptr;
  const auto* map = std::get_if<Map>(call.arguments());
  if (!map) return nullptr;
  const auto found = map->find(Value(key));
  return found == map->end() ? nullptr : &found->second;
}
std::string PathArgument(const flutter::MethodCall<Value>& call) {
  const auto* value = Argument(call, "path");
  const auto* path = value ? std::get_if<std::string>(value) : nullptr;
  if (!path) Fail("invalid_file");
  return *path;
}

Value LanAddresses() {
  ULONG size = 15 * 1024;
  std::vector<uint8_t> buffer(size);
  ULONG status = ERROR_BUFFER_OVERFLOW;
  for (int attempt = 0; attempt < 3; ++attempt) {
    buffer.resize(size);
    status = GetAdaptersAddresses(AF_INET,
        GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
        nullptr, reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data()), &size);
    if (status != ERROR_BUFFER_OVERFLOW) break;
    if (size > 4 * 1024 * 1024) Fail("network_unavailable");
  }
  if (status == ERROR_NO_DATA) return Value(List{});
  if (status != NO_ERROR) Fail("network_unavailable");
  List addresses;
  for (auto* adapter = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
       adapter; adapter = adapter->Next) {
    if (adapter->OperStatus != IfOperStatusUp ||
        (adapter->IfType != IF_TYPE_ETHERNET_CSMACD &&
         adapter->IfType != IF_TYPE_IEEE80211)) continue;
    MIB_IF_ROW2 row{};
    row.InterfaceLuid = adapter->Luid;
    if (GetIfEntry2(&row) != NO_ERROR ||
        !row.InterfaceAndOperStatusFlags.HardwareInterface ||
        row.InterfaceAndOperStatusFlags.FilterInterface ||
        row.InterfaceAndOperStatusFlags.NotMediaConnected) continue;
    for (auto* address = adapter->FirstUnicastAddress; address; address = address->Next) {
      if (!address->Address.lpSockaddr ||
          address->Address.lpSockaddr->sa_family != AF_INET ||
          address->DadState != IpDadStatePreferred) continue;
      const auto* ipv4 = reinterpret_cast<const sockaddr_in*>(address->Address.lpSockaddr);
      char text[INET_ADDRSTRLEN]{};
      if (InetNtopA(AF_INET, const_cast<IN_ADDR*>(&ipv4->sin_addr), text, sizeof(text))) {
        addresses.emplace_back(std::string(text));
      }
    }
  }
  return Value(addresses);
}
}  // namespace

bool ValidReaderKey(const std::string& key) {
  return !key.empty() && key.size() <= 160 && std::all_of(key.begin(), key.end(), [](unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') || c == ':' || c == '_' || c == '-';
  });
}
bool ValidReaderBrand(const std::string& brand) {
  static const std::set<std::string> brands{"kindle", "nook", "kobo", "pocketbook", "onyx", "other"};
  return brands.count(brand) != 0;
}
void ReaderPreferences(const flutter::MethodCall<Value>& call, std::unique_ptr<Result> result) {
  if (call.method_name() != "read" && call.method_name() != "write") { result->NotImplemented(); return; }
  HKEY raw = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\BRIZFI\\ReaderPreferences", 0, nullptr, 0,
      KEY_QUERY_VALUE | KEY_SET_VALUE, nullptr, &raw, nullptr) != ERROR_SUCCESS) {
    result->Error("unavailable", "Preference storage unavailable"); return;
  }
  struct RegistryKey { HKEY key; ~RegistryKey() { RegCloseKey(key); } } owned{raw};
  Map saved;
  // Bounded native enumeration, including malformed external registry entries.
  for (DWORD index = 0; index < 128; ++index) {
    wchar_t name[161] = {}; wchar_t data[32] = {};
    DWORD name_size = 161, data_size = sizeof(data), type = 0;
    const auto status = RegEnumValueW(raw, index, name, &name_size, nullptr, &type,
        reinterpret_cast<BYTE*>(data), &data_size);
    if (status == ERROR_NO_MORE_ITEMS) break;
    if (status != ERROR_SUCCESS || type != REG_SZ || data_size < sizeof(wchar_t) ||
        data_size > sizeof(data) || data_size % sizeof(wchar_t) != 0 ||
        data[data_size / sizeof(wchar_t) - 1] != L'\0') continue;
    if (!std::all_of(name, name + name_size, [](wchar_t c) { return c > 0 && c < 128; }) ||
        !std::all_of(data, data + data_size / sizeof(wchar_t) - 1, [](wchar_t c) { return c > 0 && c < 128; })) continue;
    const auto key = Utf8(std::wstring(name, name_size));
    const auto brand = Utf8(data);
    if (ValidReaderKey(key) && ValidReaderBrand(brand)) saved.emplace(Value(key), Value(brand));
  }
  if (call.method_name() == "read") { result->Success(Value(saved)); return; }
  const auto* key_value = Argument(call, "key");
  const auto* brand_value = Argument(call, "brand");
  const auto* key = key_value ? std::get_if<std::string>(key_value) : nullptr;
  const auto* brand = brand_value ? std::get_if<std::string>(brand_value) : nullptr;
  if (!key || !brand || !ValidReaderKey(*key) || !ValidReaderBrand(*brand)) {
    result->Error("invalid_arguments", "Invalid reader preference"); return;
  }
  DWORD value_count = 0;
  if (RegQueryInfoKeyW(raw, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr,
      &value_count, nullptr, nullptr, nullptr, nullptr) != ERROR_SUCCESS) {
    result->Error("unavailable", "Preference storage unavailable"); return;
  }
  if (!saved.count(Value(*key)) && value_count >= 128) {
    result->Error("preferences_full", "Reader preference limit reached"); return;
  }
  const auto name = Wide(*key), data = Wide(*brand);
  if (RegSetValueExW(raw, name.c_str(), 0, REG_SZ, reinterpret_cast<const BYTE*>(data.c_str()),
      static_cast<DWORD>((data.size() + 1) * sizeof(wchar_t))) != ERROR_SUCCESS) {
    result->Error("unavailable", "Preference storage unavailable"); return;
  }
  result->Success();
}
class NativeChannels::Impl {
 public:
  Impl(HWND window, flutter::BinaryMessenger* messenger)
      : state_(std::make_shared<State>(window)),
        imports_(messenger, "ru.mkulkov.brizfi/import", &flutter::StandardMethodCodec::GetInstance()),
        usb_(messenger, "ru.mkulkov.brizfi/usb", &flutter::StandardMethodCodec::GetInstance()),
        network_(messenger, "ru.mkulkov.brizfi/network", &flutter::StandardMethodCodec::GetInstance()),
        preferences_(messenger, "ru.mkulkov.brizfi/reader_preferences", &flutter::StandardMethodCodec::GetInstance()) {
    preferences_.SetMethodCallHandler(ReaderPreferences);
    imports_.SetMethodCallHandler([this](const auto& call, auto result) { Import(call, std::move(result)); });
    usb_.SetMethodCallHandler([this](const auto& call, auto result) { Usb(call, std::move(result)); });
    network_.SetMethodCallHandler([state = state_](const auto& call, auto result) {
      if (call.method_name() != "lanAddresses") { result->NotImplemented(); return; }
      // Independent of imports/USB so polling cannot take a conversion lease's
      // native busy slot. Adapter enumeration performs no external requests.
      auto reply = std::shared_ptr<Result>(std::move(result));
      std::thread([state, reply]() {
        Value value;
        bool success = false;
        try { value = LanAddresses(); success = true; } catch (...) {}
        state->Post([reply, value = std::move(value), success]() {
          if (success) reply->Success(value);
          else reply->Error("network_unavailable", "Local network is unavailable.");
        });
      }).detach();
    });
  }
  ~Impl() {
    imports_.SetMethodCallHandler(nullptr);
    usb_.SetMethodCallHandler(nullptr);
    network_.SetMethodCallHandler(nullptr);
    preferences_.SetMethodCallHandler(nullptr);
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->stopped = true;
    state_->cancelled = true;
    state_->replies.clear();
    state_->wake.notify_all();
  }
  void Drain() {
    std::vector<std::function<void()>> replies;
    { std::lock_guard<std::mutex> lock(state_->mutex); replies.swap(state_->replies); }
    for (auto& reply : replies) reply();
  }
 private:
  void Run(std::unique_ptr<Result> result, std::function<Value(const std::shared_ptr<State>&)> work) {
    if (state_->busy.exchange(true)) { result->Error("busy", "A native operation is already active."); return; }
    state_->cancelled = false;
    auto shared_result = std::shared_ptr<Result>(std::move(result));
    const auto state = state_;
    std::thread([this, state, shared_result, work = std::move(work)]() {
      const HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
      Value value;
      std::string error;
      try {
        Check(initialized, "unavailable");
        value = work(state);
      } catch (const Failure& failure) { error = state->cancelled ? "usb_cancelled" : failure.code; }
        catch (...) { error = state->cancelled ? "usb_cancelled" : "native_failed"; }
      if (SUCCEEDED(initialized)) CoUninitialize();
      state->Post([this, state, shared_result, value = std::move(value), error]() {
        state->busy = false;
        if (error.empty()) shared_result->Success(value);
        else shared_result->Error(error, "The native operation could not be completed.");
        for (const auto& result : cancellations_) result->Success();
        cancellations_.clear();
      });
    }).detach();
  }
  void Import(const flutter::MethodCall<Value>& call, std::unique_ptr<Result> result) {
    const auto method = call.method_name();
    if (method == "pickBooks" || method == "pickBook" || method == "pickAzw3") {
      Run(std::move(result), [method](const auto& state) {
        return PickBooks(state, method == "pickBooks", method == "pickAzw3");
      });
      return;
    }
    if (method == "takeSharedBook") { result->Success(); return; }
    if (method != "reserveConversion" && method != "finishConversion" &&
        method != "releaseImport" && method != "clearExpiredImports") { result->NotImplemented(); return; }
    std::string path;
    try { if (method != "clearExpiredImports") path = PathArgument(call); }
    catch (const Failure& failure) { result->Error(failure.code, "The managed copy is unavailable."); return; }
    Run(std::move(result), [method, path](const auto& state) {
      if (method == "clearExpiredImports") {
        ClearExpiredImports(state);
        return Value();
      }
      const fs::path input(Wide(path));
      const auto directory = OwnedDirectory(input);
      const auto key = Lower(directory.wstring());
      if (method == "releaseImport") {
        if (state->reservations.count(key)) Fail("busy");
        RemoveOwned(directory);
        state->live.erase(key);
        return Value();
      } else if (method == "reserveConversion") {
        if (SamePath(input, directory) || input.filename() == kMarker || state->reservations.count(key)) Fail("busy");
        // Keep alternate reader outputs. Reserve room for one full new output
        // in addition to every existing managed file; never evict a sibling.
        const uint64_t current = TreeBytes(directory);
        if (Accounted(state) + kFileLimit > kQuota) Fail("cache_full");
        state->reservations[key] = State::Reservation{input.wstring(), current};
        state->live.insert(key);
      } else {
        const auto reservation = state->reservations.find(key);
        if (reservation != state->reservations.end() && !SamePath(input, fs::path(reservation->second.input))) Fail("busy");
        state->reservations.erase(key);
        if (Accounted(state) > kQuota) Fail("cache_full");
        for (const auto* suffix : {L".converted.azw3", L".converted.epub"}) {
          const auto output = fs::path(input.wstring() + suffix);
          std::error_code error;
          if (fs::exists(output, error) && TreeBytes(output) > kFileLimit) Fail("cache_full");
          if (error) Fail("storage_unavailable");
        }
      }
      std::error_code error;
      fs::last_write_time(directory / kMarker, fs::file_time_type::clock::now(), error);
      if (error) Fail("storage_unavailable");
      return Value();
    });
  }
  void Usb(const flutter::MethodCall<Value>& call, std::unique_ptr<Result> result) {
    const auto method = call.method_name();
    if (method == "cancel") {
      if (!state_->busy) { result->Success(); return; }
      state_->cancelled = true;
      state_->wake.notify_all();
      cancellations_.emplace_back(std::move(result));
      return;
    }
    if (method == "listDevices") { Run(std::move(result), ListDevices); return; }
    if (method != "sendBook" && method != "sendBookViaDocuments") { result->NotImplemented(); return; }
    try {
      const auto path = PathArgument(call);
      const auto* id = Argument(call, "deviceId");
      int32_t device = 0;
      if (id && std::holds_alternative<int32_t>(*id)) device = std::get<int32_t>(*id);
      else if (id && std::holds_alternative<int64_t>(*id) && std::get<int64_t>(*id) > 0 &&
               std::get<int64_t>(*id) <= INT32_MAX) device = static_cast<int32_t>(std::get<int64_t>(*id));
      else Fail("usb_disconnected");
      Run(std::move(result), [this, path, device](const auto& state) {
        return SendBook(state, device, fs::path(Wide(path)), [this, state](const std::string& phase) {
          state->Post([this, phase]() { usb_.InvokeMethod("phase", std::make_unique<Value>(phase)); });
        });
      });
    } catch (const Failure& failure) { result->Error(failure.code, "The managed copy is unavailable."); }
  }
  std::shared_ptr<State> state_;
  flutter::MethodChannel<Value> imports_, usb_, network_, preferences_;
  std::vector<std::shared_ptr<Result>> cancellations_;
};
NativeChannels::NativeChannels(HWND window, flutter::BinaryMessenger* messenger)
    : impl_(std::make_unique<Impl>(window, messenger)) {}
NativeChannels::~NativeChannels() = default;
bool NativeChannels::HandleMessage(UINT message) {
  if (message != kReplyMessage) return false;
  impl_->Drain();
  return true;
}
