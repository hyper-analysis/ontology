'use strict';
const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
function activate(tab) {
  tabs.forEach(candidate => {
    const selected = candidate === tab;
    candidate.setAttribute('aria-selected', String(selected));
    candidate.tabIndex = selected ? 0 : -1;
    document.getElementById(candidate.getAttribute('aria-controls')).hidden = !selected;
  });
}
tabs.forEach((tab, index) => {
  tab.addEventListener('click', () => activate(tab));
  tab.addEventListener('keydown', event => {
    let next;
    if (event.key === 'ArrowRight') next = tabs[(index + 1) % tabs.length];
    if (event.key === 'ArrowLeft') next = tabs[(index + tabs.length - 1) % tabs.length];
    if (event.key === 'Home') next = tabs[0];
    if (event.key === 'End') next = tabs[tabs.length - 1];
    if (!next) return;
    event.preventDefault(); activate(next); next.focus();
  });
});
document.querySelectorAll('[data-copy]').forEach(button => {
  button.addEventListener('click', async () => {
    const text = document.getElementById(button.dataset.copy).textContent;
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = 'Copied';
      document.getElementById('announcement').textContent = 'Installation commands copied.';
      setTimeout(() => { button.textContent = 'Copy'; }, 2000);
    } catch {
      button.textContent = 'Select commands';
      const selection = window.getSelection();
      const range = document.createRange();
      range.selectNodeContents(document.getElementById(button.dataset.copy));
      selection.removeAllRanges(); selection.addRange(range);
      document.getElementById('announcement').textContent = 'Commands selected. Use your browser copy shortcut.';
    }
  });
});
