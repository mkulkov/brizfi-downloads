// Each language has a stable, crawlable URL with complete static content.
(() => {
  'use strict';
  const picker = document.getElementById('language');
  const language = document.documentElement.lang;
  picker.value = language;
  picker.addEventListener('change', () => {
    if (picker.value === language) return;
    if (picker.value !== 'ru' && picker.value !== 'en') return;
    const target = picker.value === 'en' ? 'en/' : '../';
    window.location.assign(new URL(target, document.baseURI).href);
  });
})();
