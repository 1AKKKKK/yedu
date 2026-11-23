# 夜读 · Yedu

本地单机的中文阅读器。EPUB 2/3 + TXT，自用，装 iOS 15.0.1 巨魔（TrollStore）上运行。

## 目标环境

| 项 | 值 |
|---|---|
| 最低系统 | **iOS 15.0**（部署目标锁定 15.0，不使用 iOS 16+ API） |
| 架构 | arm64 |
| 签名 | **不签名**（`CODE_SIGNING_ALLOWED=NO`），由巨魔安装时 fake sign |
| Bundle ID | com.yg.yedu |
| 屏幕 | 仅竖屏、仅 iPhone |

## 三步出包（不用 Mac）

1. 在 GitHub 新建一个 **public** 仓库，把本目录全部文件拖到网页上传（不需要 git）
2. 打开仓库的 **Actions** 标签 → 左侧 `build-ipa` → 右侧 `Run workflow`
3. 约 8–10 分钟跑完，进这次运行页面底部下载 **Artifacts → Yedu-unsigned-ipa**，解压得到 `Yedu.ipa`

## 装到手机

把 `Yedu.ipa` 传到手机（AirDrop / iCloud Drive / 微信文件传输都行）→ 用**巨魔**打开 → Install。

巨魔装未签名 ipa 不需要证书、不需要开发者账号。

## 目录结构

```
project.yml                     XcodeGen 工程描述（改 BundleID/版本在这里）
Sources/ReadApp.swift           入口，处理「用夜读打开」
Sources/Models.swift            Book 模型、LibraryStore、EPUB 元数据、TXT 编码识别
Sources/LibraryView.swift       书架界面、导入、筛选、删除
Sources/Info.plist              由 XcodeGen 生成，已在 project.yml 里声明
.github/workflows/build-ipa.yml GitHub Actions 出包流程
```

## 已实现（第一阶段）

- 书架：封面 / 标题 / 作者 / 进度条 / 三态筛选 / 搜索
- 导入：文件选择器（可选 iCloud Drive）、分享与「用夜读打开」、`Documents/Books` 目录直放
- EPUB 元数据：标题、作者、封面提取（container.xml → OPF → cover-image）
- TXT：UTF-8 / UTF-16 / GB18030 编码识别，字数统计
- 数据：`Documents/library.json` 持久化，`Documents/` 对「文件」App 可见（`UIFileSharingEnabled`）

## 下一阶段

- 浮动菜单（选中后悬浮四色按钮，替代系统弹窗）
- EPUB 内嵌字体与自定义字体文件导入
- 多书签列表页、按章笔记筛选

## 已实现（第二阶段）

- 阅读器：`ReaderView`（WKWebView）+ 自控 CSS 排版，分页 / 滚动双模式、四色主题 + 夜间
- 中文排版：首行缩进、段距、`line-break: strict` 避头尾、中西文自动加细空格、行距可调
- 目录：EPUB3 nav / EPUB2 navPoint / TXT 自动分章，点击跳转
- 进度：`locatorChapter` + `locatorFraction` 记忆，退出自动写回，书架进度条同步
- 高亮：长按选中 → 四色高亮（`HighlightStore`，`Documents/notes.json`），点按重绘
- 书签：面板一键加/删
- 笔记总览：按章列出、点击跳回、左滑删除、导出 Markdown / 纯文本（`ShareSheet`）
- 章内搜索：计数 + 滚动到首条命中
- 备份：`BackupManager` 打包书 + 封面 + 索引 + 笔记到 `Documents/Backup`，保留 5 份，支持从文件恢复
- 设置页：字号 / 行距 / 字体 / 翻页 / 混排间距 / 避头尾 / 备份管理
- 阅读时屏幕常亮（`isIdleTimerDisabled`）

## 已知限制

- 高亮定位用「章内纯文本字符偏移」，改动排版不影响；但如果换书源（同章文字变化）会错位
- 恢复备份后需要重启 App 才会重新加载书库索引
- 音量键翻页未做

## 注意

- 不要改用 iOS 16+ 的 API（`NavigationStack`、`Charts`、`@Observable`、`presentationDetents`、双参数 `onChange` 等），否则巨魔机器上会闪退或编译失败
- `Docs/` 里所有源码走 SwiftPM 依赖 `ZIPFoundation`（EPUB 解压用），Actions 环境联网自动拉取
