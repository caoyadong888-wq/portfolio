(function () {
  var tabs = document.querySelectorAll("[data-tab]");
  if (!tabs.length) return;
  document.body.classList.add("js");
  function show(id) {
    var panels = document.querySelectorAll("[data-panel]");
    for (var i = 0; i < panels.length; i++) {
      panels[i].classList.toggle("active", panels[i].getAttribute("data-panel") === id);
    }
    for (var j = 0; j < tabs.length; j++) {
      tabs[j].classList.toggle("active", tabs[j].getAttribute("data-tab") === id);
    }
  }
  for (var k = 0; k < tabs.length; k++) {
    tabs[k].addEventListener("click", function (event) {
      event.preventDefault();
      show(this.getAttribute("data-tab"));
    });
  }
  show("overview");
})();
