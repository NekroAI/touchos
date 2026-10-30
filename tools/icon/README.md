# 品牌资产

规范见 `docs/brand.md`，决定见 `docs/decisions.md` D43。

- `render-brand.swift`：生成应用图标、README 图标与横排 logo 的脚本，用法见文件头部。
- `AppIcon-1024.png`：应用图标原图。

生成 `Resources/AppIcon.icns`：

```sh
mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s tools/icon/AppIcon-1024.png --out AppIcon.iconset/icon_${s}x${s}.png
  sips -z $((s*2)) $((s*2)) tools/icon/AppIcon-1024.png --out AppIcon.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
```

菜单栏图标不用图片，由 `Sources/TouchOS/App/BrandMark.swift` 用同一条路径绘制；改造型时两处一起改，`docs/assets/mark.svg` 也要同步。
