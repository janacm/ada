class Iyf < Formula
  desc "Maximized-window alert when long terminal commands or agent turns finish"
  homepage "https://github.com/janacm/iyf"
  url "https://github.com/janacm/iyf/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "REPLACE_WITH_TARBALL_SHA256"
  license "MIT"
  head "https://github.com/janacm/iyf.git", branch: "main"

  # macOS only: the alert is an AppKit/WebKit window, wired through launchd and
  # the macOS frontmost-app APIs. The Command Line Tools provide the Swift
  # toolchain and macOS SDK needed to build iyf-alert; full Xcode is not required.
  depends_on :macos

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release", "--product", "iyf-alert"
    system "swift", "build", "--disable-sandbox", "-c", "release", "--product", "iyf-menubar"

    # Install the repo tree intact into libexec. Every script resolves its
    # siblings relative to its own location (iyf.sh -> lib/iyf-show-alert.sh ->
    # ../iyf-alert), so preserving the layout means the path resolution keeps
    # working with no code changes. Dir["*"] skips dotfiles, so .build is left out.
    libexec.install Dir["*"]

    # Drop the built helpers where __iyf_find_native_alert looks first
    # ($repo/iyf-alert), so the installer never tries to rebuild into the
    # read-only Cellar.
    libexec.install ".build/release/iyf-alert"
    libexec.install ".build/release/iyf-menubar"

    bin.install_symlink libexec/"iyf-alert"
    bin.install_symlink libexec/"iyf-menubar"

    # Front door for the existing onboarding installer. Kept as a thin wrapper
    # so all the relative-path logic in iyf-install.sh resolves against libexec.
    (bin/"iyf-setup").write <<~SH
      #!/bin/bash
      exec "#{libexec}/iyf-install.sh" "$@"
    SH
  end

  def caveats
    <<~EOS
      iyf is installed but not yet wired up. Run:

        iyf-setup

      That presents an interactive selector and edits ~/.zshrc and (if present)
      ~/.claude / ~/.codex hook configs, and can install the Paseo LaunchAgent
      watcher. It writes timestamped backups before any JSON edit and is
      idempotent, so re-run it any time to change which integrations are active.

      Scriptable form:

        iyf-setup --agents terminal,claude,codex
        iyf-setup --list
    EOS
  end

  test do
    # --list short-circuits before any system mutation, so it is safe to run in
    # the sandbox and proves the script + its bundled deps are wired correctly.
    assert_match "terminal", shell_output("#{bin}/iyf-setup --list")
    assert_path_exists bin/"iyf-alert"
  end
end
