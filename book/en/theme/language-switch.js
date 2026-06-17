(function () {
  function targetHref() {
    var file = window.location.pathname.split("/").pop() || "index.html";
    return "../zh/" + file;
  }

  function addLanguageSwitch() {
    var menu = document.querySelector(".menu-bar");
    if (!menu || document.querySelector(".language-switch")) return;

    var link = document.createElement("a");
    link.className = "language-switch";
    link.href = targetHref();
    link.textContent = "中文";
    link.title = "Switch to Chinese documentation";
    menu.appendChild(link);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", addLanguageSwitch);
  } else {
    addLanguageSwitch();
  }
})();
