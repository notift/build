// The Notift forms script. Served from the site's own domain at /_notift/embed/forms.js.
//
// Source: infra/build/embed/forms.js in notift-hosting. Job 2 of build-and-publish.yml copies it
// into every site image, over anything the customer build put at that path. The dashboard cannot
// change this file. What platform-01 can still answer on the customer origin is bounded at the edge
// instead: only a POST that asks for JSON reaches it, answered as inert JSON (render_live_route in
// infra/runtime/lib/common.sh).
//
// The site passes the public Turnstile site key on the script tag:
//   <script src="/_notift/embed/forms.js" data-sitekey="0x..." defer></script>
// A new version of this file reaches a site with its next build, and goes through staging first.
(() => {
  // The public site key comes from the script tag, never from a server at run time.
  const tag = document.currentScript;
  const given = tag && tag.dataset ? tag.dataset.sitekey : "";
  const key = typeof given === "string" && /^[0-9A-Za-z_-]{8,64}$/.test(given) ? given : null;
  const path = /^\/_notift\/forms\/[a-z0-9-]{1,40}$/;
  const redirect = value => typeof value === "string" && value.length <= 200 && /^\/(?!\/)/.test(value) && !value.includes("\\") && !/[\u0000-\u001f\u007f]/.test(value) ? value : null;
  const show = (form, name, success) => {
    // Like Webflow: show the block itself, without an anchor in the address bar. Otherwise a reload
    // or a shared link shows the message again.
    const done = document.getElementById(name + "-verzonden");
    const failed = document.getElementById(name + "-mislukt");
    const target = success ? done : failed;
    if (done) done.style.display = "none";
    if (failed) failed.style.display = "none";
    if (target) {
      target.style.display = "block";
      if (success) form.style.display = "none";
      return;
    }
    let message = form.nextElementSibling;
    if (!message || !message.matches("[data-notift-form-message]")) {
      message = document.createElement("p"); message.dataset.notiftFormMessage = ""; message.setAttribute("role", "status"); form.after(message);
    }
    message.textContent = success ? "Bedankt, je bericht is verstuurd." : "Versturen is niet gelukt. Probeer het opnieuw, of neem op een andere manier contact op.";
  };
  const forms = [...document.forms].filter(form => path.test(new URL(form.action, location.href).pathname));
  if (!forms.length || window.__notiftFormsLoaded) return;
  window.__notiftFormsLoaded = true;
  // Without a valid site key Turnstile cannot run and the handler refuses every post. Say so at once,
  // so a missing attribute shows on staging instead of after a visitor typed a message.
  if (!key) { console.error("Notift forms: data-sitekey is missing or invalid on the script tag"); forms.forEach(form => show(form, new URL(form.action, location.href).pathname.split("/").pop(), false)); return; }
  const api = document.createElement("script"); api.src = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit"; api.async = true; api.defer = true; document.head.append(api);
  forms.forEach(form => {
    const name = new URL(form.action, location.href).pathname.split("/").pop();
    const submit = form.querySelector('[type="submit"]'); if (!submit) return;
    const honeypot = document.createElement("input"); honeypot.name = "website"; honeypot.tabIndex = -1; honeypot.autocomplete = "off"; honeypot.setAttribute("aria-hidden", "true"); honeypot.style.cssText = "position:absolute;left:-10000px;width:1px;height:1px;overflow:hidden"; form.append(honeypot);
    const box = document.createElement("div"); submit.before(box); submit.disabled = true;
    let widget;
    const fail = () => { show(form, name, false); submit.disabled = false; if (widget !== undefined && window.turnstile) window.turnstile.reset(widget); };
    const timer = setTimeout(fail, 15000);
    const render = () => { if (!window.turnstile) return setTimeout(render, 50); widget = window.turnstile.render(box, { sitekey: key, appearance: "interaction-only", callback: () => { clearTimeout(timer); submit.disabled = false; }, "expired-callback": () => { submit.disabled = true; } }); };
    api.addEventListener("load", render);
    form.addEventListener("submit", async event => { event.preventDefault(); submit.disabled = true; try { const reply = await fetch(form.action, { method: "POST", body: new FormData(form), headers: { Accept: "application/json" }, credentials: "same-origin" }); const body = await reply.json().catch(() => null); if (!reply.ok || !body || body.ok !== true) return fail(); const to = redirect(new FormData(form).get("_redirect")); if (to) location.assign(to); else { form.reset(); show(form, name, true); if (widget !== undefined && window.turnstile) window.turnstile.reset(widget); } } catch { fail(); } });
  });
})();
