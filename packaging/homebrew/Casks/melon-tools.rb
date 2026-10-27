cask "melon-tools" do
  version "2.4.1"
  sha256 "b237f890ef9bb36dd374c0121b938365d6f8c9d316283ac10046d7445f5d8fad"

  url "https://github.com/ivankuprin/MelonTools/releases/download/v#{version}/MelonTools-#{version}.dmg"
  name "Melon Tools"
  desc "Codex account pool, local gateway, and scheduled model tasks"
  homepage "https://github.com/ivankuprin/MelonTools"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Melon Tools.app"

  zap trash: [
    "~/Library/Application Support/MelonTools",
    "~/Library/Caches/dev.melontools.app",
    "~/Library/Logs/MelonTools",
    "~/Library/Preferences/dev.melontools.app.plist",
  ]
end
