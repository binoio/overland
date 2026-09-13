---
layout: default
title: Overland
description: Overland is a native macOS client for GlobalProtect VPN portals, built on gpclient from GlobalProtect-openconnect.
---

<section class="hero">
  <div class="container">
    <img src="{{ '/icon.png' | relative_url }}" alt="" width="128" height="128" style="border-radius: 28px; margin-bottom: 1rem;">
    <h1>Overland</h1>
    <p>Connect to a GlobalProtect VPN portal from the menu bar — sign in with your browser, approve once, and never see a password prompt for the tunnel again.</p>
    <div class="hero-actions">
      <a href="https://github.com/binoio/overland/releases/latest" class="btn btn-primary">
        <i class="fas fa-download"></i>
        Download Latest
      </a>
      <a href="https://github.com/binoio/overland" class="btn btn-ghost" target="_blank">
        <i class="fab fa-github"></i>
        View on GitHub
      </a>
    </div>
  </div>
</section>

<section id="features" class="section">
  <div class="container">
    <h2>Features</h2>

    <div class="features-grid">
      <div class="feature-card">
        <div class="feature-icon"><i class="fas fa-globe"></i></div>
        <h4>Single Sign-On</h4>
        <p>SAML sign-in happens in your own browser, then hands back to the app. Password and client-certificate logins work too.</p>
      </div>

      <div class="feature-card">
        <div class="feature-icon"><i class="fas fa-user-shield"></i></div>
        <h4>Approve once</h4>
        <p>A small privileged helper, approved once in System Settings, opens the tunnel. No sudo, no password prompt on every connect.</p>
      </div>

      <div class="feature-card">
        <div class="feature-icon"><i class="fas fa-bars"></i></div>
        <h4>Lives in the menu bar</h4>
        <p>Connect, disconnect and see status from a standard menu; optionally hide the Dock icon entirely.</p>
      </div>

      <div class="feature-card">
        <div class="feature-icon"><i class="fas fa-chart-area"></i></div>
        <h4>Live session view</h4>
        <p>Gateway, session expiry, tunnel address and live throughput while connected.</p>
      </div>

      <div class="feature-card">
        <div class="feature-icon"><i class="fas fa-rotate"></i></div>
        <h4>Survives restarts</h4>
        <p>Quit disconnects cleanly; after a crash the app re-attaches to the running tunnel with its log intact.</p>
      </div>

      <div class="feature-card">
        <div class="feature-icon"><i class="fas fa-terminal"></i></div>
        <h4>Built on gpclient</h4>
        <p>The proven CLI from GlobalProtect-openconnect and OpenConnect do the VPN work; Overland is the native front end.</p>
      </div>
    </div>
  </div>
</section>

<section id="how-it-works" class="section architecture">
  <div class="container">
    <h2>How it works</h2>

    <div class="features-grid">
      <div class="feature-card">
        <h4>1. Sign in as you</h4>
        <p><code>gpauth</code> runs unprivileged: it opens your browser for the portal's SAML page and receives the result through the <code>globalprotectcallback:</code> URL macOS routes to Overland.</p>
      </div>

      <div class="feature-card">
        <h4>2. Tunnel as root</h4>
        <p>The privileged helper — a launchd daemon inside the app bundle, registered with SMAppService — runs the bundled <code>gpclient</code> with the sign-in result on stdin. It accepts only Overland itself, verifies code signatures before every launch, and allow-lists every argument.</p>
      </div>

      <div class="feature-card">
        <h4>3. Watch and control</h4>
        <p>gpclient's JSON log stream drives the UI: gateways, tunnel up, session lifetime, warnings and errors. Disconnect sends a clean interrupt; routes and DNS are restored.</p>
      </div>
    </div>
  </div>
</section>

<section id="getting-started" class="section">
  <div class="container">
    <h2>Getting Started</h2>

    <div class="features-grid">
      <div class="feature-card">
        <h4>Install</h4>
        <p>Download the latest release, move <strong>Overland.app</strong> to <strong>/Applications</strong>, and open it.</p>
      </div>

      <div class="feature-card">
        <h4>Set up</h4>
        <p>Enter your portal address, keep Single Sign-On selected, and click <strong>Enable…</strong> to approve the helper in System Settings › Login Items &amp; Extensions.</p>
      </div>

      <div class="feature-card">
        <h4>Connect</h4>
        <p>Click Connect, finish signing in in the browser, and allow it to open Overland. That's it — from then on, one click from the menu bar.</p>
      </div>
    </div>

    <p style="margin-top: 1.5rem;">Requires macOS 14 or later. Overland is open source under the GPL-3.0; see the <a href="https://github.com/binoio/overland/blob/main/OverlandApp/README.md">README</a> for building from source.</p>
  </div>
</section>
