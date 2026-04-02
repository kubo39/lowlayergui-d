# Low-layer GUI in D

## prerequiresites

### ツールチェーン

- D コンパイラ (DMD or LDC2)
- DUB パッケージマネージャ

### システムライブラリ

```sh
apt install \
  libwayland-dev \
  wayland-protocols \
  libvulkan-dev \
  vulkan-validationlayers \
  libharfbuzz-dev \
  libxkbcommon-dev \
  libfreetype-dev \
  fonts-noto-cjk \
  glslang-tools
```

| ライブラリ | 用途 |
|-----------|------|
| `libwayland-dev` | Wayland コンポジタとの通信 |
| `wayland-protocols` | xdg-shell 等の XML プロトコル定義 |
| `libvulkan-dev` | GPU 描画 |
| `vulkan-validationlayers` | 開発時デバッグ |
| `libharfbuzz-dev` | テキストシェーピング |
| `libxkbcommon-dev` | キーボードレイアウト変換 |
| `libfreetype-dev` | TTF フォント読み込み・アウトライン取得 |
| `fonts-noto-cjk` | CJK フォント (日本語テキスト表示に必要) |
| `glslang-tools` | GLSL シェーダの SPIR-V コンパイル |

### 動作環境

Wayland コンポジタが必要。Linux デスクトップ環境 (GNOME/KDE/sway 等) または WSL2 (WSLg) で動作する。
