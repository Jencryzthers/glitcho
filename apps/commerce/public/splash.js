(() => {
  const splash = document.getElementById('boot-splash');
  if (!splash) {
    return;
  }

  const dismiss = () => {
    splash.classList.add('boot-splash-hidden');
    setTimeout(() => {
      if (splash && splash.parentNode) {
        splash.parentNode.removeChild(splash);
      }
    }, 520);
  };

  if (document.readyState === 'complete') {
    setTimeout(dismiss, 1050);
  } else {
    window.addEventListener(
      'load',
      () => {
        setTimeout(dismiss, 1050);
      },
      { once: true }
    );
  }
})();
