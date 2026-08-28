# Homebrew cask の雛形。
#
# これは「置いてあるだけ」のファイルで、まだどの tap にも公開されていない。
# 公開するときは Suemura/homebrew-tap リポジトリの Casks/ へこの内容をコピーし、
# `brew install --cask suemura/tap/dropvert` で入る形にする。
#
# 配布物ではなくソースから利用者の手元でビルドする形にしているのは、
# Apple Developer Program の証明書による署名と公証（notarization）を持たないため。
# ビルド済みの .app をダウンロードさせると quarantine 属性が付き、
# 「開発元を確認できないため開けません」になる。ad-hoc 署名は公証の代わりにならない。
#
# version は VERSION ファイルと必ず一致させること。ズレていたら lint.sh が落ちる。
#
# リリース時の手順は README の「リリース」節を参照。sha256 はタグの tarball から
# 取得する:
#   curl -sL https://github.com/Suemura/dropvert/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256

cask "dropvert" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256"

  url "https://github.com/Suemura/dropvert/archive/refs/tags/v#{version}.tar.gz",
      verified: "github.com/Suemura/dropvert/"
  name "Dropvert"
  desc "Drag-and-drop image converter for macOS"
  homepage "https://github.com/Suemura/dropvert"

  # cwebp / gif2webp。WebP 出力に必要（他の形式は sips だけで動く）。
  depends_on formula: "webp"

  # 展開したソースをその場でビルドし、成果物を app artifact として渡す。
  # installer script: ではなく preflight + app にしているのは、artifact を
  # 持たない形にすると brew uninstall がアプリを消せなくなるため。
  preflight do
    system_command "#{staged_path}/build.sh",
                   args: [staged_path.to_s],
                   print_stdout: true
  end

  app "Dropvert.app"

  zap trash: [
    "~/Library/Preferences/io.github.suemura.dropvert.plist",
  ]

  caveats <<~EOS
    ビルドに swiftc（Xcode Command Line Tools）が必要です。未インストールの場合:
      xcode-select --install

    ad-hoc 署名のアプリのため、初回起動が Gatekeeper に阻まれる場合があります。
    その場合は次でインストールし直してください:
      brew install --cask --no-quarantine suemura/tap/dropvert
  EOS
end
