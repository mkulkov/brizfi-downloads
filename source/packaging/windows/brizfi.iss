#ifndef StageDir
  #error StageDir must point to the staged Windows release
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef FileVersion
  #error FileVersion is required
#endif

[Setup]
AppId={{73E9046F-6885-4C0D-A3EC-3614F1542D73}
AppName=BRIZFI
AppVersion={#AppVersion}
AppPublisher=Maksim Kulkov
AppPublisherURL=https://mkulkov.github.io/brizfi-downloads/
AppSupportURL=https://github.com/mkulkov/brizfi-downloads/issues
DefaultDirName={localappdata}\Programs\BRIZFI
DefaultGroupName=BRIZFI
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename=BRIZFI-{#AppVersion}-windows-x64-setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\brizfi.exe
LicenseFile={#StageDir}\LICENSE
InfoAfterFile={#StageDir}\INSTALLATION.txt
VersionInfoVersion={#FileVersion}
VersionInfoDescription=BRIZFI Setup
VersionInfoProductName=BRIZFI
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\BRIZFI"; Filename: "{app}\brizfi.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\BRIZFI"; Filename: "{app}\brizfi.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\brizfi.exe"; Description: "{cm:LaunchProgram,BRIZFI}"; Flags: nowait postinstall skipifsilent
