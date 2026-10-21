
(function () {
  var nodes = document.querySelectorAll("img.badge-live");
  function fail(img) {
    if (img.getAttribute("data-failed") === "1") {
      return;
    }
    img.setAttribute("data-failed", "1");
    var fallback = img.getAttribute("data-fallback");
    if (fallback) {
      img.setAttribute("src", fallback);
    }
    var noteId = img.getAttribute("data-note");
    var note = noteId ? document.getElementById(noteId) : null;
    if (note) {
      note.hidden = false;
    }
  }
  nodes.forEach(function (img) {
    img.addEventListener("error", function () { fail(img); });
    if (img.complete && img.naturalWidth === 0) {
      fail(img);
    }
  });
})();
