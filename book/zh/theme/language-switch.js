(function () {
  function targetHref() {
    var file = window.location.pathname.split("/").pop() || "index.html";
    return "../en/" + file;
  }

  function addLanguageSwitch() {
    var buttons = document.querySelector(".right-buttons");
    if (!buttons || document.querySelector(".language-switch")) return;

    var link = document.createElement("a");
    link.className = "icon-button language-switch";
    link.href = targetHref();
    link.textContent = "English";
    link.title = "Switch to English documentation";
    buttons.insertBefore(link, buttons.firstChild);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", addLanguageSwitch);
  } else {
    addLanguageSwitch();
  }
})();
