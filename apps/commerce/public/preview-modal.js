(function () {
  const modal = document.getElementById('preview-modal');
  const image = document.getElementById('preview-modal-image');
  if (!modal || !image) {
    return;
  }

  const closeSelectors = '[data-preview-close]';
  const triggerSelector = '.preview-tile[data-preview-full]';

  function closeModal() {
    modal.classList.remove('preview-modal-open');
    modal.setAttribute('aria-hidden', 'true');
    image.setAttribute('src', '');
    image.setAttribute('alt', '');
    document.body.classList.remove('preview-modal-lock');
  }

  function openModal(fullURL, altText) {
    if (!fullURL) {
      return;
    }
    image.setAttribute('src', fullURL);
    image.setAttribute('alt', altText || 'Preview image');
    modal.classList.add('preview-modal-open');
    modal.setAttribute('aria-hidden', 'false');
    document.body.classList.add('preview-modal-lock');
  }

  document.addEventListener('click', event => {
    const closeTarget = event.target.closest(closeSelectors);
    if (closeTarget) {
      closeModal();
      return;
    }

    const previewTrigger = event.target.closest(triggerSelector);
    if (!previewTrigger) {
      return;
    }

    const fullURL = previewTrigger.getAttribute('data-preview-full') || '';
    const altText = previewTrigger.getAttribute('data-preview-alt') || '';
    openModal(fullURL, altText);
  });

  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && modal.classList.contains('preview-modal-open')) {
      closeModal();
    }
  });
})();
