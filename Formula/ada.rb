class Ada < Formula
  desc "Maximized-window alert when long terminal commands or agent turns finish"
  homepage "https://github.com/janacm/ada"
  url "https://github.com/janacm/ada/archive/refs/tags/v0.2.tar.gz"
  sha256 "6da55d018ba549818716ce94a62ae193b17e39e89088202193abf94cb4295456"
  license "MIT"
  head "https://github.com/janacm/ada.git", branch: "main"

  # release.sh cuts plain annotated git tags; this repo publishes no GitHub
  # "releases", so :github_latest would read /releases/latest and 404. Read the
  # tags instead, with an explicit regex so a future pre-release tag (v1.0-rc1)
  # can't outrank a stable one.
  livecheck do
    url :stable
    strategy :git
    regex(/^v?(\d+(?:\.\d+)+)$/i)
  end

  # macOS only: the alert is an AppKit/WebKit window, wired through launchd and
  # the macOS frontmost-app APIs. The Command Line Tools provide the Swift
  # toolchain and macOS SDK needed to build ada-alert; full Xcode is not required.
  depends_on :macos

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release", "--product", "ada-alert"
    system "swift", "build", "--disable-sandbox", "-c", "release", "--product", "ada-menubar"

    # Install the repo tree intact into libexec. Every script resolves its
    # siblings relative to its own location (ada.sh -> lib/ada-show-alert.sh ->
    # ../ada-alert), so preserving the layout means the path resolution keeps
    # working with no code changes. Dir["*"] skips dotfiles, so .build is left out.
    libexec.install Dir["*"]

    # Drop the built helpers where __ada_find_native_alert looks first
    # ($repo/ada-alert), so the installer never tries to rebuild into the
    # read-only Cellar.
    libexec.install ".build/release/ada-alert"
    libexec.install ".build/release/ada-menubar"

    bin.install_symlink libexec/"ada-alert"
    bin.install_symlink libexec/"ada-menubar"

    # Front door for the existing onboarding installer. Kept as a thin wrapper
    # so all the relative-path logic in ada-install.sh resolves against libexec.
    #
    # opt_libexec, NOT libexec: the installer bakes its own directory into
    # durable user config (the ~/.zshrc source line, the Claude/Codex hook
    # commands, the Paseo LaunchAgent plist). #{libexec} is the VERSIONED Cellar
    # path, which `brew upgrade` deletes — every wired integration would then
    # point at a directory that no longer exists. opt_libexec is the
    # version-stable symlink, so upgrades are transparent.
    (bin/"ada-setup").write <<~SH
      #!/bin/bash
      exec "#{opt_libexec}/ada-install.sh" "$@"
    SH
  end

  def caveats
    <<~EOS
      ada is installed but not yet wired up. Run:

        ada-setup

      That presents an interactive selector and edits ~/.zshrc and (if present)
      ~/.claude / ~/.codex hook configs, and can install the Paseo LaunchAgent
      watcher. It writes timestamped backups before any JSON edit and is
      idempotent, so re-run it any time to change which integrations are active.

      Scriptable form:

        ada-setup --agents terminal,claude,codex
        ada-setup --list

      Upgrades: `brew upgrade ada` is enough — the wiring points at the
      version-stable #{opt_libexec}, so it survives upgrades and you do not
      need to re-run ada-setup.

      Upgrading FROM v0.2: that release wired itself to a versioned Cellar
      path, so run `ada-setup` once after upgrading to repoint it.
    EOS
  end

  test do
    # --list short-circuits before any system mutation, so it is safe to run in
    # the sandbox and proves the script + its bundled deps are wired correctly.
    assert_match "terminal", shell_output("#{bin}/ada-setup --list")
    assert_path_exists bin/"ada-alert"
  end
end
