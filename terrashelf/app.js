(function () {
  var cards = Array.prototype.slice.call(document.querySelectorAll("[data-module]"));
  var query = document.getElementById("q");
  var category = document.getElementById("category");
  if (!query || !category) {
    return;
  }
  function applyFilter(catalog) {
    var names = {};
    (catalog.modules || []).forEach(function (entry) {
      names[entry.name] = entry.category;
    });
    var text = query.value.toLowerCase();
    var selected = category.value;
    cards.forEach(function (card) {
      var name = card.getAttribute("data-module");
      var known = Object.prototype.hasOwnProperty.call(names, name);
      var haystack = card.textContent.toLowerCase();
      var categoryMatch = selected === "all" || card.getAttribute("data-category") === selected;
      card.hidden = !(known && categoryMatch && (!text || haystack.indexOf(text) !== -1));
    });
  }
  function useEmbedded() {
    var node = document.getElementById("catalog-data");
    applyFilter(JSON.parse(node.textContent));
  }
  query.addEventListener("input", function () {
    useEmbedded();
  });
  category.addEventListener("change", function () {
    useEmbedded();
  });
  fetch("catalog.json").then(function (response) {
    return response.json();
  }).then(function (catalog) {
    applyFilter(catalog);
  }).catch(function () {
    useEmbedded();
  });
})();
