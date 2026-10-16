export function LandingPage() {
  return (
    <main className="landing-shell">
      <nav className="landing-nav" aria-label="Main navigation">
        <a className="landing-brand" href="/" aria-label="Axo home">
          <span className="auth-brand-mark" aria-hidden="true">A</span>
          <span>Axo</span>
        </a>
        <a className="landing-nav-link" href="/app">Open Axo</a>
      </nav>
      <section className="landing-hero">
        <p className="auth-eyebrow">YOUR TERMINAL, WHEREVER YOU ARE</p>
        <h1>Pick up where your<br /><span>Mac left off.</span></h1>
        <p className="landing-description">
          Axo lets you return to terminal sessions running on your own Mac. Sign in with Cloudflare to get started.
        </p>
        <a className="auth-primary-button landing-cta" href="/app">Continue to Axo <span aria-hidden="true">→</span></a>
        <p className="auth-footnote">Your Mac remains yours. Axo never stores terminal output or commands in account metadata.</p>
      </section>
    </main>
  );
}
