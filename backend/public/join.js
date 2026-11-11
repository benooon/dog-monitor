// Progressive enhancement for /join: posts the form as JSON and shows the result in place.
// Without JavaScript the form still posts and the server redirects back with ?joined=1 or ?error=.
(() => {
  const form = document.querySelector("form.join");
  const video = document.querySelector(".hero-media video");

  if (video && window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    video.removeAttribute("autoplay");
    video.pause();
  }
  if (!form) return;

  const status = form.querySelector(".status");
  const success = form.querySelector(".success");
  const email = form.querySelector('input[name="email"]');

  const show = (state, message) => {
    form.dataset.state = state;
    status.textContent = message || "";
    if (state === "joined") success.focus();
    if (state === "error") email.setAttribute("aria-invalid", "true");
    else email.removeAttribute("aria-invalid");
  };

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!email.checkValidity()) {
      show("error", form.dataset.msgEmail);
      email.focus();
      return;
    }
    show("sending");
    const body = { email: email.value, locale: form.elements.locale.value };
    if (form.elements.source.value) body.source = form.elements.source.value;
    try {
      const res = await fetch("/waitlist", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      });
      if (res.status === 202) show("joined");
      else if (res.status === 429) show("error", form.dataset.msgBusy);
      else if (res.status === 400) show("error", form.dataset.msgEmail);
      else show("error", form.dataset.msgNetwork);
    } catch {
      show("error", form.dataset.msgNetwork);
    }
  });
})();
