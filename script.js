const tabs = document.querySelectorAll(".tour-tab");
const panels = document.querySelectorAll(".tour-panel");
const screen = document.querySelector(".tour-screen");

tabs.forEach((tab) => {
  tab.addEventListener("click", () => {
    const target = tab.dataset.tour;

    tabs.forEach((item) => item.classList.toggle("active", item === tab));
    panels.forEach((panel) => {
      panel.classList.toggle("active", panel.dataset.panel === target);
    });

    if (screen && target) {
      screen.dataset.activeTour = target;
    }
  });
});
