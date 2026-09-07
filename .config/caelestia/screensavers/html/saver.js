// Shared boilerplate for the screensaver pages.
//
// Every saver is opened as  file://.../<name>.html?mon=<MONITOR>  by
// screensaver.py, which then finds the window by title and fullscreens it on
// that monitor. Firefox has no --class flag, so the *title* is the only handle
// hyprland gets -- keep it in sync with TITLE_PREFIX in screensaver.py.
(function () {
    const params = new URLSearchParams(location.search);
    const mon = params.get('mon') || 'default';
    document.title = 'caelestia-saver@' + mon;

    // Full-bleed black, no cursor, no scrollbars.
    const style = document.createElement('style');
    style.textContent =
        'html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;' +
        'background:#000;cursor:none}canvas{display:block;width:100vw;height:100vh}';
    document.head.appendChild(style);
})();

// Sizes a canvas to the viewport in device pixels and keeps it that way.
// `onResize(w, h)` is called once immediately and again on every resize, with
// the *device pixel* dimensions the drawing code should use.
function fitCanvas(canvas, onResize) {
    function resize() {
        const dpr = window.devicePixelRatio || 1;
        const w = Math.round(window.innerWidth * dpr);
        const h = Math.round(window.innerHeight * dpr);
        if (canvas.width !== w || canvas.height !== h) {
            canvas.width = w;
            canvas.height = h;
        }
        if (onResize) onResize(w, h);
    }
    window.addEventListener('resize', resize);
    resize();
    return resize;
}

const rand = (a, b) => a + Math.random() * (b - a);
const randInt = (a, b) => Math.floor(rand(a, b + 1));
const pick = arr => arr[Math.floor(Math.random() * arr.length)];
