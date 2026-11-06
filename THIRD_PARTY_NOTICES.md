# 第三方组件与许可

选片工具本身按 **GPL-3.0-or-later** 发布（见 `LICENSE`），免费、开源，不提供任何担保。下面这些不是本项目写的，
各按自己的许可随本项目分发。

## spektrafilm（光谱胶片色调）

- 作者：Andrea Volpato — https://github.com/andreavolpato/spektrafilm
- 用到的部分：
  - `culling-poc/LabelGUI/Scripts/bake_film_luts.py` 调用 spektrafilm（代码 GPL-3.0）离线生成色调表。
    spektrafilm 本身不随 app 分发，app 运行时不调用它。
  - `third_party/film-luts/*.cube`：用 spektrafilm 的胶片 / 相纸数据生成的 3D LUT。
    **许可 CC BY-SA 4.0**（https://creativecommons.org/licenses/by-sa/4.0/），
    许可全文和作者的说明见 `third_party/film-luts/SPEKTRAFILM_LICENSE.txt`，
    相对 spektrafilm 完整渲染的改动见同目录的 `CHANGELOG.txt`。
- 这些表随 app 以原样的 `.cube` 文本放在 `选片工具.app/Contents/Resources/film-luts/`，可以自由取出、
  按 CC BY-SA 4.0 再分发。
- 选片工具不是 spektrafilm 官方项目，也没有得到它的作者背书。色调用的是通用名，不代表任何胶片厂商的产品。
- 光谱色调的说明里写了「参考：Kodak Portra 400」这类片名，指的是这款色调用了哪支胶片的公开数据（经 spektrafilm 模拟、
  再按扫描调过色），不代表原厂效果。Kodak、Portra、Ektar、UltraMax、Kodachrome、Vision3、Fujifilm、Velvia、Provia 等
  是各自所有者的商标；选片工具与这些公司没有关联，也没有得到它们的背书。

## UnifrakturCook 字体

- 拼图「英文花体」用的字体，以 base64 嵌在 `CollageEmbeddedFonts.swift` 里。
- 许可 SIL Open Font License 1.1（OFL-1.1），不属于 GPL。全文和来源见 `third_party/fonts/UnifrakturCook/`，
  随 app 放在 `Contents/Resources/fonts/`。
