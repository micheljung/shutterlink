import PhotoSwipeLightbox from './photoswipe-lightbox.esm.min.js?v={{v:photoswipe-lightbox.esm.min.js}}';

const SAFETY_POLL_MS = 10000;
const FALLBACK_POLL_MS = 5000;
const OPEN_TIMEOUT_MS = 10000;
const MAX_ERRORS = 3;
const DOWNLOAD_BUTTON_ORDER = 8;
const DELETE_BUTTON_ORDER = 7;
const PENDING_TEXT = 'Preparing preview…';
const FAILED_TEXT = 'No preview. Tap to download';
const DOWNLOAD_ICON =
  '<path d="M20.5 14.3 17.1 18V10h-2.2v7.9l-3.4-3.6L10 16l6 6.1 6-6.1ZM23 23H9v2h14Z" id="pswp__icn-download"/>';
const DELETE_PHOTO_TEXT = 'Delete this photo for everyone with the link?';
const DELETE_FAILED_TEXT = "Couldn't delete. Please try again.";

const grid = document.querySelector('ul.photos[data-live]');
if (grid) start(grid);

function start(grid) {
  const counter = document.querySelector('[data-count]');
  const galleryForm = document.querySelector('form.delete-gallery');
  const deleteTemplate = grid.querySelector('form.delete').cloneNode(true);
  const trashPath = deleteTemplate.querySelector('path').getAttribute('d');
  const deletedHere = new Set();
  const base = new URL('.', new URL(grid.dataset.live, location.href)).pathname;
  const anchors = new Map();
  for (const a of grid.querySelectorAll('li > a[download]')) {
    anchors.set(keyOf(a), a);
  }

  const lightbox = new PhotoSwipeLightbox({
    gallery: grid,
    children: 'a[data-pswp-width]',
    pswpModule: () => import('./photoswipe.esm.min.js?v={{v:photoswipe.esm.min.js}}'),
  });
  lightbox.on('uiRegister', () => {
    lightbox.pswp.ui.registerElement({
      name: 'download',
      title: 'Download',
      order: DOWNLOAD_BUTTON_ORDER,
      isButton: true,
      tagName: 'a',
      html: { isCustomSVG: true, inner: DOWNLOAD_ICON, outlineID: 'pswp__icn-download' },
      onInit: (button, pswp) => {
        pswp.on('change', () => {
          const original = pswp.currSlide.data.element;
          button.href = original.href;
          button.download = original.getAttribute('download');
        });
      },
    });
    lightbox.pswp.ui.registerElement({
      name: 'delete',
      title: 'Delete photo',
      order: DELETE_BUTTON_ORDER,
      isButton: true,
      html: {
        isCustomSVG: true,
        inner: `<path d="${trashPath}" id="pswp__icn-delete"/>`,
        outlineID: 'pswp__icn-delete',
      },
      onClick: async (event, button, pswp) => {
        const key = keyOf(pswp.currSlide.data.element);
        if (!confirm(DELETE_PHOTO_TEXT)) return;
        if (!(await post(`${base}p/${key}/delete`))) return;
        pswp.close();
        deletedLocally(key);
      },
    });
  });
  let buffered = null;
  lightbox.on('destroy', () => setTimeout(() => {
    if (!buffered || lightbox.pswp) return;
    render(buffered);
    buffered = null;
  }));
  lightbox.init();

  let etag = `"${grid.dataset.generation}"`;
  let inFlight = false;
  let dirty = false;
  let gone = false;
  let polling = false;
  let source = null;
  let openTimer = null;
  let timer = null;

  async function refresh() {
    if (gone) return;
    if (inFlight) {
      dirty = true;
      return;
    }
    inFlight = true;
    try {
      const response = await fetch(grid.dataset.live, {
        cache: 'no-store',
        headers: { 'If-None-Match': etag },
      });
      if (response.status === 304 || !response.ok) return;
      const tag = response.headers.get('ETag');
      const data = await response.json();
      if (!tag && data.photos.length === 0) {
        stop();
        if (anchors.size > 0) location.reload();
        return;
      }
      if (tag) etag = tag;
      apply(data);
    } catch {
      // A failed refresh is retried by the next event or poll.
    } finally {
      inFlight = false;
      if (dirty && !gone) {
        dirty = false;
        refresh();
      }
    }
  }

  function apply(data) {
    if (lightbox.pswp) {
      buffered = data;
      return;
    }
    render(data);
  }

  function keyOf(a) {
    return a.getAttribute('download').replace(/\.jpg$/, '');
  }

  async function post(url) {
    const response = await fetch(url, { method: 'POST' }).catch(() => null);
    if (response?.ok) return true;
    alert(DELETE_FAILED_TEXT);
    return false;
  }

  function removeTile(key) {
    const a = anchors.get(key);
    if (!a) return;
    a.parentElement.remove();
    anchors.delete(key);
  }

  function updateCount() {
    if (counter) counter.textContent = String(anchors.size);
    if (anchors.size === 0) location.reload();
  }

  function deletedLocally(key) {
    deletedHere.add(key);
    removeTile(key);
    updateCount();
  }

  function deleteForm(key, index) {
    const form = deleteTemplate.cloneNode(true);
    form.action = `${base}p/${key}/delete`;
    form.querySelector('button').setAttribute('aria-label', `Delete photo ${index + 1}`);
    return form;
  }

  grid.addEventListener('submit', async (event) => {
    const form = event.target.closest('form.delete');
    if (!form) return;
    event.preventDefault();
    const key = keyOf(form.parentElement.querySelector('a[download]'));
    if (!confirm(DELETE_PHOTO_TEXT)) return;
    if (await post(form.action)) deletedLocally(key);
  });

  if (galleryForm) {
    galleryForm.addEventListener('submit', async (event) => {
      event.preventDefault();
      const text =
        `Delete all ${anchors.size} photos for everyone with the link? ` +
        "This can't be undone.";
      if (!confirm(text)) return;
      if (await post(galleryForm.action)) location.reload();
    });
  }

  function render(data) {
    const photos = data.photos.filter((photo) => !deletedHere.has(photo.key));
    const current = new Set(photos.map((photo) => photo.key));
    for (const key of [...anchors.keys()]) {
      if (!current.has(key)) removeTile(key);
    }
    photos.forEach((photo, index) => {
      const existing = anchors.get(photo.key);
      if (existing) {
        if (stateOf(existing) !== photo.state) fill(existing, photo, index);
        return;
      }
      const a = document.createElement('a');
      a.href = `${base}p/${photo.key}.jpg`;
      a.download = `${photo.key}.jpg`;
      fill(a, photo, index);
      const li = document.createElement('li');
      li.append(a, deleteForm(photo.key, index));
      grid.append(li);
      anchors.set(photo.key, a);
    });
    updateCount();
  }

  function stateOf(a) {
    if (a.dataset.pswpWidth) return 'ready';
    return a.querySelector('.failed') ? 'failed' : 'pending';
  }

  function fill(a, photo, index) {
    if (photo.state !== 'ready') {
      const placeholder = document.createElement('span');
      placeholder.className = `placeholder ${photo.state}`;
      placeholder.textContent = photo.state === 'failed' ? FAILED_TEXT : PENDING_TEXT;
      a.replaceChildren(placeholder);
      return;
    }
    a.dataset.pswpSrc = `${base}v/${photo.key}.jpg`;
    a.dataset.pswpWidth = String(photo.w);
    a.dataset.pswpHeight = String(photo.h);
    const img = document.createElement('img');
    img.alt = `Photo ${index + 1}`;
    img.loading = 'lazy';
    img.decoding = 'async';
    img.addEventListener('load', () => img.classList.add('fresh'), { once: true });
    img.src = `${base}t/${photo.key}.jpg`;
    a.replaceChildren(img);
  }

  function connect() {
    if (gone || polling || document.hidden || source) return;
    const since = etag.replace(/^W\//, '').replace(/^"|"$/g, '');
    const events = new EventSource(`${grid.dataset.events}?since=${encodeURIComponent(since)}`);
    let errors = 0;
    source = events;
    openTimer = setTimeout(fallback, OPEN_TIMEOUT_MS);
    events.onopen = () => {
      errors = 0;
      clearTimeout(openTimer);
    };
    events.onmessage = () => refresh();
    events.onerror = () => {
      if (source !== events) return;
      errors += 1;
      if (events.readyState === EventSource.CLOSED || errors >= MAX_ERRORS) fallback();
    };
  }

  function disconnect() {
    clearTimeout(openTimer);
    if (source) source.close();
    source = null;
  }

  function schedule() {
    clearInterval(timer);
    if (gone || document.hidden) return;
    timer = setInterval(refresh, polling ? FALLBACK_POLL_MS : SAFETY_POLL_MS);
  }

  function fallback() {
    if (polling || gone) return;
    polling = true;
    disconnect();
    refresh();
    schedule();
  }

  function stop() {
    gone = true;
    disconnect();
    clearInterval(timer);
  }

  document.addEventListener('visibilitychange', () => {
    if (gone) return;
    if (document.hidden) {
      disconnect();
      clearInterval(timer);
      return;
    }
    connect();
    refresh();
    schedule();
  });

  if (window.EventSource) {
    connect();
    schedule();
  } else {
    fallback();
  }
}
