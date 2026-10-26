// English translations are trusted page content; Russian is the static HTML fallback.
(() => {
  'use strict';
  const english = {
  "skip": "Skip to content",
  "navHow": "How it works",
  "navDownload": "Download",
  "intro": "From your phone or PC to your e-reader",
  "hero": "Good books.<br>Ready to travel.",
  "lead": "Choose a book, send it to your e-reader and keep reading. BRIZFI helps your next story find its way.",
  "storeHero": "Download for Android<small>APK · 0.1.1 · GitHub</small>",
  "windowsHero": "Download for Windows<small>EXE · x64 · 0.1.1</small>",
  "local": "No sign-up. Your books transfer locally.",
  "storePending": "Android 10 or later · APK from GitHub.",
  "note": "Your book.<br>Your e-reader.<br>Your story.",
  "connections": "Wi-Fi and USB",
  "connectionHint": "Connect the way that suits you",
  "kindleFormats": "Prepare books for Kindle",
  "noCloud": "No cloud transfers",
  "yourDevices": "Your files stay on your devices",
  "howTitle": "Less setup.<br>More reading.",
  "howIntro": "One simple route from file to e-reader.",
  "step1Title": "Connect your e-reader",
  "step1": "For Wi-Fi, connect both devices to the same network, open the address shown in BRIZFI in your e-reader’s browser and confirm the connection. Or choose USB.",
  "step2Title": "Choose your books",
  "step2": "Add files to the app. Prepare EPUB and FB2 for Kindle, or transfer an existing AZW3 file without conversion.",
  "step3Title": "Transfer and read",
  "step3": "With Wi-Fi, download the book from the page in your e-reader’s browser. With USB, send it from the app. Then open the book on your e-reader.",
  "privacyTitle": "Books travel.<br>Privacy stays with you.",
  "privacy": "No account or cloud upload is needed to transfer a book. Conversion runs on your own device.",
  "network": "For Wi-Fi transfers, use a trusted local network and keep the app open until the transfer finishes.",
  "requirements": "What you need to connect <span aria-hidden=\"true\">↗</span>",
  "compatTitle": "Before you connect",
  "faq1Title": "Which e-readers are supported?",
  "faq1": "Transferring and opening test books has been verified on Kindle Basic 2024. EPUB transfer to NOOK over USB has also been verified on Windows. Other models and connection methods need separate testing.",
  "faq2Title": "Which file formats can I transfer?",
  "faq2": "For Kindle, EPUB and FB2 can be converted to AZW3; existing AZW3 files transfer unchanged. Supported NOOK devices use EPUB. Whether a book opens depends on the e-reader. DRM-protected books are not supported.",
  "faq3Title": "How do I install the Windows version?",
  "faq3": "Download and run the Windows x64 EXE installer. Choose an installation folder, then open BRIZFI from the Start menu. Administrator rights are not required. A portable ZIP is also available in the GitHub release.",
  "faq4Title": "Do transfers need internet access?",
  "faq4": "Local transfers do not need internet access. For Wi-Fi, both devices must share a network and the e-reader’s browser must be able to open the local page. HTTP traffic is not encrypted, so use a trusted network. Downloading the app requires internet access.",
  "downloadIntro": "Your next chapter is waiting",
  "downloadTitle": "Take your books with you.",
  "platforms": "BRIZFI for Android and Windows.",
  "store": "Android APK 0.1.1",
  "windows": "Windows 0.1.1 on GitHub <span aria-hidden=\"true\">↗</span>",
  "tagline": "Choose a book. Send it. Read.",
  "releases": "All releases",
  "source": "Source code · GPL-3.0-or-later",
  "homeLabel": "BRIZFI — home",
  "navLabel": "Main navigation",
  "connectAlt": "A phone sends a book to an e-reader",
  "transferAlt": "A book parcel flies from a phone to an e-reader"
};
  const nodes = [...document.querySelectorAll('[data-i18n]')];
  const originals = new Map(nodes.map(node => [node, node.innerHTML]));
  const attributes = ['aria-label', 'alt'];
  const attributeNodes = attributes.flatMap(attribute =>
    [...document.querySelectorAll(`[data-i18n-${attribute}]`)].map(node => ({
      node, attribute, key: node.getAttribute(`data-i18n-${attribute}`),
      original: node.getAttribute(attribute),
    })));
  const description = document.querySelector('meta[name="description"]');
  const ogTitle = document.querySelector('meta[property="og:title"]');
  const ogDescription = document.querySelector('meta[property="og:description"]');
  const russianMetadata = [document.title, description.content, ogDescription.content];
  const picker = document.getElementById('language');
  const supported = value => value === 'ru' || value === 'en';
  const storageKey = 'brizfi-language';

  function applyLanguage(language) {
    document.documentElement.lang = language;
    for (const node of nodes) {
      node.innerHTML = language === 'en' ? english[node.dataset.i18n] : originals.get(node);
    }
    for (const {node, attribute, key, original} of attributeNodes) {
      node.setAttribute(attribute, language === 'en' ? english[key] : original);
    }
    document.title = language === 'en' ? 'BRIZFI — books on your e-reader' : russianMetadata[0];
    description.content = language === 'en'
      ? 'Transfer books from Android or Windows to your e-reader. Local Wi-Fi or USB transfers, with EPUB and FB2 preparation for Kindle.'
      : russianMetadata[1];
    ogTitle.content = document.title;
    ogDescription.content = language === 'en'
      ? 'Choose a book. Send it to your e-reader. Read. An app for Android and Windows.'
      : russianMetadata[2];
    picker.value = language;
  }

  let savedLanguage;
  try { savedLanguage = localStorage.getItem(storageKey); } catch { /* Storage can be blocked. */ }
  const browserLanguage = (navigator.languages?.[0] || navigator.language || 'en').toLowerCase();
  applyLanguage(supported(savedLanguage) ? savedLanguage : browserLanguage.startsWith('ru') ? 'ru' : 'en');
  picker.addEventListener('change', () => {
    const language = picker.value;
    if (!supported(language)) return;
    applyLanguage(language);
    try { localStorage.setItem(storageKey, language); } catch { /* Switching still works without storage. */ }
  });
})();
