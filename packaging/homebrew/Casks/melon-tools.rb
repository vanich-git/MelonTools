cask "melon-tools" do
  version "6.5.1"
  sha256 "f2b92902fa375433f94a18d89a56ffcde0e067c9df935544f529bb6fbc968b7b"

  url "https://github.com/vanich-git/MelonTools/releases/download/v#{version}/MelonTools-#{version}.dmg"
  name "Melon Tools"
  desc "Codex account pool, local gateway, and scheduled model tasks"
  homepage "https://github.com/vanich-git/MelonTools"

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
