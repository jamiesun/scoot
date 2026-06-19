(function () {
  function targetHref() {
    var file = window.location.pathname.split("/").pop() || "index.html";
    return "../zh/" + file;
  }

  function addLanguageSwitch() {
    var buttons = document.querySelector(".right-buttons");
    if (!buttons || document.querySelector(".language-switch")) return;

    var link = document.createElement("a");
    link.className = "language-switch";
    link.href = targetHref();
    link.textContent = "中文";
    link.title = "Switch to Chinese documentation";
    link.setAttribute("aria-label", "Switch to Chinese documentation");
    buttons.insertBefore(link, buttons.firstChild);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", addLanguageSwitch);
  } else {
    addLanguageSwitch();
  }
})();
