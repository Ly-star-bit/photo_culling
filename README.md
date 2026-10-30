# 选片工具 (photo_culling)

给摄影师用的 AI 辅助批量选片工具，macOS 原生应用，全部本地运行，不上传任何照片（除非你自己接上云端的 AI 助手，见「给 AI 用（MCP）」）。

导入一场拍摄（支持 RAW / RAW+JPG / JPG），几秒内完成技术性废片检测（闭眼、虚焦、曝光问题、连拍去重），再用本地视觉模型对幸存照片做语义复核，最终以 XMP 星级色标写回 Lightroom / Capture One，或直接导出交付 JPG。

## 功能

- **存储卡导入**：插上相机存储卡（根目录有 DCIM 的卡）自动弹框问要不要导入，确认后复制到「图片 › 当天日期」（如 `~/Pictures/20261014`），导完直接打开并开始分析（正在挑片 / 审片时不打断，留一条「打开并分析」横幅）。只复制、不删不改卡上任何文件；每个文件先写临时文件、整份 SHA-256 校验通过才改正式名，中途取消不留半截；目标里同名不同内容的整组（RAW+JPG 一起）改名 `_2` 绝不覆盖，复制时也按整张看，不会把 RAW 和 JPG 拆开；「目标里已经有了」要整份逐字节一样才算；导过的照片记账（文件名+大小+头尾指纹，不靠 FAT 卡不准的修改时间），再插同一张卡只导新的，也可以勾「以前导入过的也再导一遍」；开始前查空间。带隐藏属性的照片照导；卡上读不出来的地方、没导的其他文件（录音备注等）都会列出来，有文件没导进来时一直提醒「先别格式化存储卡」直到你关掉。多张卡排队导，前面在分析时可以「停下分析并导入」（已分析的下次直接复用），最后一张导完再一起分析。卡早就插着的话：文件夹菜单「从存储卡导入…」。视频暂不导入
- **原生极速分析**：ImageIO + Vision 框架，约 0.04 秒/张（M4 Max，3072px 解码），1000 张一分钟内扫完
- **闭眼检测（动态阈值）**：按连拍组内每个人自己的睁眼基线判定（组内最高 EAR 的 70%），眯眼、小眼型不再被冤杀；极低值兜底防整组闭眼漏判。合影里的小脸（分析图上不到画面 0.3%）从原图按脸框裁块、在原分辨率上重新读眼睛，九人以上的大合影也能判出谁闭眼；一个人的街拍里背后的小路人不算（主角的脸独大时小脸照旧不判）
- **对焦检测（五官 ROI）**：锐度只在眼+眉、嘴部区域计算（Tenengrad 梯度 + 高斯降噪），头发和背景纹理不参与投票；无人脸照片自动切换到原生抠图的主体区域
- **曝光检测**：曝光裁切 = 死白/死黑像素占比（三通道同时裁切才算，红花不误报），有人脸时只算人（脸扩到头和上半身），屋檐下、黑背景里的死黑不把曝光正常的人像判废；远景里人太小时照旧算整张；另有「欠曝」「过曝」：脸的亮度太暗、而且整张没有一处是亮的（闪光灯没闪），或者脸亮到没层次，固定标准不设滑杆；低调人像不误判，深肤色、深色衣服在正常光里也不会（还要整张没有一处亮才算欠曝），复审时和曝光裁切问同一个问题
- **文件损坏检测**：读卡出错、拷贝中断留下的半截 JPEG（ImageIO 会把缺的部分补成灰色照常解码）按 JPEG 文件结束标记认出来，带「文件损坏」直接判废片、不送 VLM 复审，状态栏一直提示「卡先别格式化」；EOI 后面接视频的动态照片、灰底棚拍、加了灰边的导出图都不误报。带隐藏属性的照片照样分析
- **连拍分组**：pHash + 时间窗聚类，组内自动挑最佳（表情 > 人脸质量 > 锐度），落单照片不发精选（精选必须赢过真实对手）
- **VLM 废片复审（平反庭）**：MiniCPM-V 4.6（1.3B，Ollama 本地运行）只复审被自动淘汰的照片，按各自罪名定向提问——虚焦→"主体清晰吗"、闭眼→"是否眯眼笑"、曝光→"是否刻意剪影/逆光"。洗清罪名自动回到可用并带"平反"徽章；VLM 只能撤销它复查过的罪名，人工改判不受影响。闭眼复审裁的是被定罪的那张脸（多人合照里 EAR 最低的主体脸，与判决规则一致），VLM 答"看不清"时维持原判而不是平反；合影小脸靠原图判出的闭眼不送复审、复审也撤销不了（预览图上那张脸只有二三十像素，VLM 看不清）。断点续跑按罪名记账：中断后重跑只处理剩余照片，调滑杆后新增的罪名只补问新罪名、保留已有结论
- **VLM 幸存者精审（可选）**：给未淘汰照片打表情分（连拍组挑精选的首要排序依据）+ 构图提示（抢镜/切肢仅作徽章）；无人脸的照片不问表情，表情分留空
- **阈值实时判决**：分析只存原始数值，拖滑杆即时重判，三档预设（宽松/标准/严格），新场次默认「标准」（连拍组内的人脸质量比较默认就开着）；升级前分析过的老场次保持原来的阈值，判决不变
- **人工优先**：键盘快速改判（1 精选 / 2 可用 / 3 废片 / 0 恢复；改判后照片换了分区，焦点留在原来的下一张，不会被带到废片区）、⌘ 多选批量改判，人工决定永远压过算法。「接受推荐」定下的判决照样钉住，但不算人工改判（不挂 ✋、不进「人工改判 N」和复盘统计）。最近菜单只留 15 场，掉出去的只清预览图，判决、人工改判、拼图都留着，重新打开那个文件夹点「重新分析」几秒补回预览。`-` `=` 调缩略图大小，⌥⌘S 收起右侧筛选面板给网格让地方
- **审片模式（F）**：全屏逐张过，1/2/3（或大图下面那排按钮）判完自动下一张并闪一下刚才判成了什么；审到连拍按 C 只挑这一场，⏎ 定完自动回到审片原来那张接着往下；右上角是这张里每个人的脸（睁闭眼圈），顶上标出是连拍里的第几张；默认「跳过废片」——最后一遍过留下的不会走进废片区（要审废片就关掉，或筛选废片再按 F）
- **连拍挑选（C）**：一组一组过连拍，全窗口并排全览——一组全部照片同时上台，张数多到一屏放不下就单行大图左右滚动对比；锐度/质量/表情最高项标绿。每张下面是**按人对齐**的人脸（几张之间同一个人落在同一个位置，这张里没检测到就留虚框），绿圈睁眼、**黄圈眯眼**（比这个人本组睁得最开的那张小四分之一以上）、红圈闭眼，★ 标出每个人眼睛最好的那张（参考 Narrative Close-ups）。点一张 = 只留它（其余当场变灰标「废」），鼠标停在照片上右上角「精选 / 可用 / 废」只改这一张（一组留几张、一张精选几张可用都点得出来），「这组全留」= 现在的精选（你点过的，没点过就是推荐的）留精选、其余可用，⌘点 = 多留，1–9 只留第几张；屏幕上只是草稿，⏎ 才写判决并跳下一个待处理组，↑/↓ 换组不丢草稿，顶上「第 3/57 组」；勾上「数字键选完直接下一组」就是一组一个键（Lightroom 的自动前进）。Z 所有格一起放大到各自的人脸（原图按人脸区域裁块，拖动/捏合联动），合影里 `[` `]` 一个人一个人地换着比；⌘Z 先撤你刚点的，再撤已确认的（会跳回那一组）
- **按分组视图**：每个连拍一行，单张收进最后的折叠区；定完的场自动叠起来只显示留下的（Aftershoot 的叠放），「显示被废的 N 张」随时展开复查；工具条显示「已定 x/y 场」；鼠标停在照片上点「只留这张」、或行头「接受推荐」一下定一场（「只看这一章」时是「本章接受推荐」）
- **缩略图悬停快捷判决**：任何一张缩略图鼠标停上去，下沿出现 ★ / ● / ✕（参考 Lightroom 网格上可点的旗标），只用鼠标也不用先选中再找批量栏
- **快捷键一览**：状态栏右下角键盘图标或按 `?`，网格 / 连拍挑选 / 审片 / 大图 / 时间轴分组列出
- **双机位**：按机身分开认（型号 + 机身序列号，两台同型号的 X-T50 / A7 IV 也分得开；读不到序列号的按型号），连拍的「场」、近似重复、精选提名都各分各的 —— 副机位插进来的一张不会把主机位的连拍拆散，同一刻的两个角度也不会互相抢精选。两台机器的钟不准时：状态栏「2 台机身」点开按机身对时，每台填偏移（+180 或 +3:00 = 往后拨 3 分钟，最多 ±48 小时），或者在网格里 ⌘ 点选两台机身同一瞬间各拍的一张，批量栏「把这两张对成同一时刻」（以照片多的那台为准）；章节、按拍摄时间排序、场的先后、审片顺序、时间轴都按对过的时间走，⌘Z 撤销，按场次保存（不改原片；导出文件名的 {日期} 也按对过的时间）。以前分析过的场次打开时只读文件头补上序列号，场和精选马上按机身分开，不用重新分析（近似重复是分析时定的，要按机身重分点一次「重新分析」，没变的照片全复用，几秒）
- **章节时间轴**：网格上方一章一段（停拍 15 分钟以上分章，宽度按张数开方分配，再多章节也不会挤出网格），多天拍摄标日期，白线标出网格里正看到的章节；悬停看这一章的代表照片、时间、张数、精选/可用/废片、还有几场连拍没定，点击跳过去，网格里 `[` `]` 上一章 / 下一章；右键「只看这一章」把网格、分组和连拍挑选都收窄到这一章（长场次、多天拍摄一章一章过），`[` `]` 直接换章
- **拼图 / 相册（拼图 tab）**：精选直接拼成可以发、可以印的成品。自动排版按照片原比例求解（切分树，缝宽处处相等，几十个备选 ←/→ 换一版），主图自动给评分最高的；按人脸安全裁切（不切脸、眼线落上三分线，小格自动收半身近景形成景别节奏），路人入画会提示；挑片按画面相似度去重。深度自定义：拖缝调大小、⌥点缝翻转、拖格子互换或拖到边上劈开插入、双击调裁切（全身/半身/特写一键取景）、锁定格子再换一批、月洞门/拱窗/圆角形状、文字格（宋体/Didot 等系统字体，竖排、字距、印章、{date_cn} 等占位符）、自定义模板存取与 JSON 分享、全部可撤销。风格：极简纸白、杂志、中式、胶片、相纸、画廊、主图取色、日系清透、电影、手账、封面，外加六套杂志风格的预设（时尚刊、留白杂志、报纸、瑞士、婚礼 fine-art、婚礼 · 古典版心）。**照片上压字**：刊头大标题、角标小字、电影字幕、竖排题字、大号期数、英文花体、手写一句，自动避开人脸和身体、按底下画面换深字浅字，也可以九宫格定位或直接拖。**统一色调**：胶片、日系、复古、电影、冷淡、黑白、旧照、报纸、高反差、哑光、雅致，外加「统一色温」把整组往主图的色温明暗上拉。**模板库**：小红书封面、日系杂志、中式、九宫格、手账散落、电影感、基础，加上六类杂志风格（见下一条），十三类 65 个，缩略图用你自己的照片现套。**手账散落**：拍立得/白边/胶片/相角斜放叠放，自动贴胶带、不压脸；和纸/条纹/圆点/牛皮纸胶带、标签、邮戳、回形针、手写字（翩翩体），拖动、旋转、缩放、叠放顺序都能调。导出：单张、朋友圈九宫格切图、小红书轮播；相册模式按章节和时间自动编排跨页（扉页、对页、去重），出血/安全区/中缝避让，每跨页 300dpi JPG + 带裁切线的印刷 PDF；文件直接写进输出目录，文件名默认是导出时间（精确到秒）或手动填，同名自动加 -2 不覆盖
- **杂志风格（拼图 tab 的六类模板 + 一键成套）**：**时尚刊** 7 款（封面「刊头在后」：人站在刊名前面挡住几个字母 ——「人物挡字」，按字形量每个字母被挡多少，挡多了依次挪取景、拉远、缩字，实在不行把刊名放回人前并写明原因；3 张脸以上的合影不挡；内页满版大片、引语单图、巨字开篇）、**底片印样** 5 款（底片条三帧 / 斜放 / 方片给社交平台，印样 135 整卷 / 6×6 给打印；齿孔、片边字、帧号，红笔圈精选、打叉废片）、**留白杂志** 5 款（暖象牙纸、四边不一样的留白、细宋标题、加字距的小字，字号按手机全屏看得清来定；窄栏文字的照片是固定竖格，想要整张横图用「小图标题」）、**报纸风** 4 款（今日头版、民国竖排繁体、英文复古、大字报；照片加网点、米色纸纹，「本报讯」正文只写 EXIF 和日历算得出的真话（日期、星期、农历、张数、机型参数），读不到的写「未记录」；大字报的标题请用中文）、**瑞士网格** 5 款（按公式求栅格、对齐基线，高反差黑白加一种强调色；巨型数字那款抠出来的人站在日期数字前面）、**婚礼相册** 5 种跨页（卡纸 + 细线，fine-art 和古典版心两个预设按册子尺寸重算边距）。版式页「模板」框里的「一键成套」：**出一期**（封面 + 3 张内页，3:4 多页，适合小红书轮播；同一个菜单里「换封面」在主图候选里轮下一张，内页留着）、**按卷出印样**（读选片结果的全部帧、含废片，一个章节一卷、一卷一页，超过 35 帧接着排下一页，每场最好的精选红圈、废片打叉）、**整本婚礼相册**（切到相册、fine-art 编排：废片不要、同一场只留精选、章节开篇、疏 → 密 → 本章精选单张收尾、竖图成对，一章里黑白照片过三分之一就整章转黑白（相册工具条「整章黑白」可关））；都能撤销。人物挡字、照片抠图、网点、卡纸、纸纹、条码 / 油性笔贴纸在别的模板上也能用；印样每一帧的记号、先后在「版式 › 印样 › 逐帧」里改。刊头、片边、报头不印真实刊名、胶片品牌和刊号，条码只是装饰（不是有效条码）；自己填了像真实刊名的字只提示一句、不拦。**测试范围**：样片只有一位模特一天拍的 21 张人像；婚礼相册的编排规则（章节开篇、整章黑白、呼吸页、竖图成对、同一场只留精选）和多人合影的人物挡字只在自检的合成数据上验过，还没在真实婚礼的照片上试过
- **交付出口**：XMP 星级+色标写回原图旁（LR/C1/Bridge 可读；精选 4–5 星绿标、可用 2–3 星、废片 -1 红标，VLM 表情分只在档内排先后，精选永远比可用星多；旁边已有 Lightroom 等写的 XMP 时只改星级/色标，调色、关键字原样保留，读不全的不碰并点名告诉你；写过之后又改了判决或客户选中，状态栏提醒「XMP 过期：改了 N 张」，点一下重写）、JPG 导出、废片一键进废纸篓（可恢复；客户选中的废片不动）
- **JPG 交付（导出 JPG / 精华 Top N / 水印页共用一套设置）**：尺寸有原尺寸、长边 4096、长边 2048（微博）、朋友圈长边 1080、小红书 3:4（1080×1440 以内）、Instagram 4:5（1080×1350 以内）、自定义长边 / 短边，都是「放进去」：不裁切、不放大（规格表在 `DeliveryExport.swift`，加平台加一行）；水印页配上「画布比例扩展」补白就是精确尺寸（3:4 + 小红书 = 1080×1440）。缩小后补一刀屏幕输出锐化（不锐化 / 屏幕·标准 / 屏幕·高，和检视器同一套 Lanczos + USM；水印页先锐化照片再合成签名和文字，水印本身不被锐化），原尺寸从不锐化。色彩：缩小的默认转 sRGB（Adobe RGB / P3 原片真转换，不是改标签；相机设成 Adobe RGB 直出、没嵌 ICC 的 JPEG 也认得），原尺寸默认保留原色彩空间（给印厂），可以改。「去掉 GPS 位置」只去拍摄地点，时间、机身镜头、版权、方向照留（精华默认打开）。「限制在 X MB 以内」超了自动降质量，压到最低质量 40 还放不下的照写并点名。文件名模板 {原名} {序号:3} {日期} {名次:2} {相机} {星级}，旁边预览第一张叫什么；默认和以前一样（导出 JPG = 原名，水印页 = 原名 + _wm；水印页的 {星级} 先看旁边的 .xmp），重名另存 -2、-3 不覆盖（导出 JPG 勾了「覆盖」才覆盖）；导出 JPG 不能选拍摄文件夹本身或里面会被分析的子文件夹（勾了覆盖会换掉原片），拍摄文件夹/导出JPG/ 照常。精华 Top N 每次导到「导出JPG/精华/」下面一个新文件夹（Top20_2026-10-21_1530），文件名默认带名次（01_、02_…，按名字排序上传就是名次顺序），不和上次的混、不删任何东西，面板里有自己的质量（以前悄悄按质量 100 导）
- **客户选片（确认表 → 导入客户选择 → 精修）**：「导出 › 导出选片确认表」出一个单文件 HTML（仅精选 / 精选 + 可用 / 选中的照片；菜单上先估好大小，约 120 KB 一张，导完报实际大小，超过 40 MB 建议只导精选或分批），微信直接发。客户点照片选中（紫色 ♥，再点取消），底部「已选 N 张 · 复制我的选择」复制出一段文字（第一行是表号，下面一行一个文件名），粘贴到微信发回来；选择记在客户的浏览器里（允许存的话），关掉再打开还在；复制不了就把文字摆出来让人长按复制；微信里网页点不了也没关系，回照片下面的文件名或编号一样能导。「导出 › 导入客户选择…」粘贴回复或打开 .txt / .csv：文件名带不带扩展名（扩展名对不上也认，比如这一场是 JPG、客户回 .CR3）、大小写、全角标点、「7207和7208」、Lightroom 清单、Pixieset 等导出的 CSV（第一行是表头才当表格，只用文件名那一列；别的列里带数字的格子列在没认出里，不悄悄扔）、文件号（7221 → DSCF7221，全场只有一张才算）、编号（12、35、78 · 12-15：按回复里带的表号对那张表，没带就按最近导出的那张，预览里写明是哪张）都认；认不出的、重号的、文件号和编号指向两张的都列出来，不猜。预览「认出 N 张 · 没认出 M 个：…」，再点「标记为客户选中」。客户选中是单独的标记，不改判决：缩略图上紫心、顶栏「客户选中 N」只看这些、状态栏计数，XMP 写紫色标（压过绿 / 红，星级不变；别人的 XMP 只改色标，取消后只在还是我们写的紫色时才拿掉）；再导是加上去（客户常分几次回），「清除客户选中」重来，都能 ⌘Z 一步撤回。「复制文件名」按选中的照片、没选就按当前筛选，三种格式：Lightroom（逗号分隔，粘到图库筛选器「文本 › 文件名 › 包含」；IMG_1 也会筛出 IMG_101 时提醒）、Capture One（空格分隔，「按文件名列表选择」）、一行一个（完整文件名，RAW+JPG 两个都列，给 Photo Mechanic「Load Selection」）。「复制原片到…」同一个范围，把原片复制（不移动）到你选的文件夹：RAW+JPG 和旁边的 .xmp 一起，目标里一模一样的跳过、同名不同内容的整张另存 -2，每个文件复制完校验大小和 SHA-256，原片一个字节不动，后台复制、顶栏能取消；不能选拍摄文件夹里面（下次分析会当成新照片），在旁边建一个精修文件夹就行；每场会记住上次选的文件夹
- **拍摄复盘**：按焦段 / ISO 统计出片率；章节保护（整段时间的照片全灭时警告，防漏交场景）
- **给 AI 用（MCP）**：Claude Code、Antigravity 这类 AI agent 能接上开着的选片工具：看当前这一场的判决、分组和照片（图由 app 出），替你改判、在网格里指出照片、套拼图模板、一键成套、换封面、改字、换样式，改动当场出现在窗口里，标题栏写着「Claude Code 已连接 / AI 正在操作…」，⌘Z 照样能撤；app 没开时只能看状态、列场次和模板，MCP 绝不会替你启动 app。「选片工具」菜单里「允许 AI 实时操作（MCP）」随时能关。配置、能做什么、安全承诺见下面「给 AI 用（MCP）」

## 架构

两阶段漏斗，重活给毫秒级的确定性算法，语义判断给小模型：

```
照片文件夹
   │
   ▼
┌─────────────────────────────────────────┐
│ 阶段一 · 原生引擎 (Swift, ~0.04s/张)      │
│  ImageIO 解码 → Vision 人脸/landmark     │
│  EAR·锐度·曝光·pHash·连拍分组 → JSON     │
└─────────────────────────────────────────┘
   │  阈值实时判决 (滑杆/预设)
   ▼
┌─────────────────────────────────────────┐
│ 阶段二 · VLM (可选, MiniCPM via Ollama)   │
│  复审废片: 按罪名定向平反 (主用法)         │
│  精审幸存: 表情分 + 构图提示              │
└─────────────────────────────────────────┘
   │
   ▼
人工审片 → XMP / JPG / 确认表
```

## 目录结构

```
culling-poc/
├── LabelGUI/            # macOS 应用 (SwiftUI, swift build 即可构建)
│   └── Sources/LabelGUI/
│       ├── Native/      # 原生分析引擎: ImageLoader / FaceAnalyzer / Metrics / AnalysisEngine
│       ├── MCP/         # 给 AI 用的 MCP 服务器 (LabelGUI --mcp: 不开界面、不读照片, 经实时桥交给 app)
│       ├── Live/        # app 一侧的实时桥 (本机 Unix socket + 锁, AI 的改动由 app 自己执行)
│       ├── BatchStore.swift   # 判决逻辑·会话管理·导出
│       └── BatchView.swift    # 批量选片界面
├── layer1.py            # Python 版一阶段 (YuNet+MediaPipe, 已被原生引擎取代, 留作对照)
├── layer2.py            # VLM 语义复核 (--backend ollama / openai)，app 里唯一会跑的 Python
├── evaluate.py          # 阈值扫描·与人工标注对比校准
├── prompts/             # VLM 提示词
├── runtime/             # 打进 app 的精简运行时 (pyproject + uv.lock: 只有 requests/tqdm/pillow)
└── pyproject.toml       # 开发环境 (含 layer1 的 mediapipe/opencv/rawpy，不进 app)
```

`build_app.sh` 只把 `layer2.py`、`common.py`、`prompts/` 和 `runtime/` 里的 pyproject/锁文件装进
`选片工具.app/Contents/Resources/culling-poc`，app 启动时同步到 `~/Library/Application Support/选片工具/runtime/culling-poc`
并在那里 `uv run python layer2.py`。首次跑 VLM 时 uv 只装这三个包（几 MB），老安装里带着
mediapipe/opencv 的 `.venv` 会被 uv 自动裁剪到同样的精简集合。

## 环境要求与安装

- Apple Silicon Mac（M1 及以上），macOS 14+
- 基础功能（分析/筛选/导出）**零外部依赖**，装 app 即用
- VLM 语义复核（可选）需要：
  - [Ollama](https://ollama.com)：`ollama pull minicpm-v4.6`（q4 版约 1.6GB，无风扇机型更凉快）
  - [uv](https://github.com/astral-sh/uv)：`brew install uv`（首次运行自动装精简运行时：requests / tqdm / pillow，几 MB）

### 安装

1. 从 [Releases](../../releases) 下载 `PhotoCulling-vX.Y.Z.dmg`，打开后把 **选片工具** 拖到 **Applications**
2. app 没有 Apple 开发者签名，首次打开会被 Gatekeeper 拦下。macOS 15 起「右键 → 打开」已不再绕过拦截，改走：
   先双击一次让系统弹出拦截提示 → **系统设置 → 隐私与安全性** → 页面底部找到「已阻止使用"选片工具"」→ **仍要打开**（只需一次）
   - macOS 14 仍可右键 app → 打开
3. 之后从启动台 / Applications 正常打开即可

### 从源码构建

```bash
cd culling-poc/LabelGUI
swift build -c release
# 产物: .build/release/LabelGUI，装进 app bundle 或直接运行
# 无头模式(测试用): LabelGUI --analyze <照片文件夹>
# 判决统计(测试用): LABELGUI_DATA_DIR=/tmp/lg LabelGUI --verdicts <照片文件夹> [--dedupe] [--per-photo 逐张列出判决和理由]
# 连拍挑选按键脚本(测试用，会写判决，用临时数据目录): LABELGUI_DATA_DIR=/tmp/lg LabelGUI --compare <照片文件夹> --take 7 --keys "2,cmd:DSCF7223,enter,undo" [--auto]
#   审片里按 C 的「只挑这一场」: --only 7
# 存储卡导入(测试用，必须给 --dest、不往真的「图片」里写): LABELGUI_DATA_DIR=/tmp/lg LabelGUI --ingest <假卡目录> --dest <目标> [--reimport] [--plan-only] [--cancel-after N|--cancel-at-bytes B] [--via-store]
#   确认框离屏快照: LABELGUI_DATA_DIR=/tmp/lg LabelGUI --card-ui <假卡目录> out.png --dest <目标> [--reimport] [--running|--importing] [--planning] [--free-bytes N]
#   排队自检(两张卡排队 / 停下分析并导入): LABELGUI_DATA_DIR=/tmp/lg LabelGUI --card-queue-selftest <卡A> <卡B> --dest <目标>
#   整套导入回归(CI 也跑，随机字节造假卡): python3 Scripts/card_import_regression.py .build/release/LabelGUI
# 不认识的 --参数（拼错、新脚本配旧程序）直接退出，不会开界面
# 从 Xcode / IDE / 调试器 / 脚本里开界面时，父进程不是 launchd、stdin 又不是终端（像是被 MCP 客户端起的）也直接退出 2：
#   真要开界面设 LABELGUI_ALLOW_GUI=1；LABELGUI_NO_GUI=1 时一律不开界面。访达 / 程序坞 / open 打开的、终端里直接跑的不受影响
# 时间轴布局自检 / 网格改判保持位置自检: LabelGUI --timeline-selftest / --ux-selftest
# 按机身对时(测试用，会写这一场的 body_offsets.json，必须临时数据目录): LABELGUI_DATA_DIR=/tmp/lg LabelGUI --body-offset <照片文件夹> [--body 'X-T50 #SECOND-BODY-0002' --seconds +3:00 | --align B_0001,DSCF7207] [--undo]
#   不带 --body / --align 只打印每台机身和偏移；两台以上机身时 --verdicts --per-photo 每行带机身、对时后的时间、章节，最后打按拍摄时间的顺序
#   对时面板离屏快照: --batch-ui <照片文件夹> out.png --body-clock-ui
# XMP 写入与过期提醒(会在原图旁写 .xmp，只对拷出来的临时文件夹跑): LABELGUI_DATA_DIR=/tmp/lg LabelGUI --export-xmp <文件夹> --then DSCF7209=废片
# 客户选片闭环(测试用，都要临时数据目录):
#   选片确认表: LABELGUI_DATA_DIR=/tmp/lg LabelGUI --proof-sheet <文件夹> --out x.html [--scope picks|picks+usable] [--ids a,b]
#   导入客户选择(打印认出 / 没认出 / 按哪张表): LABELGUI_DATA_DIR=/tmp/lg LabelGUI --client-import <文件夹> (--text 回复.txt | --clear) [--apply] [--undo]
#   复制文件名清单(打到 stdout，不进剪贴板): LABELGUI_DATA_DIR=/tmp/lg LabelGUI --copy-list <文件夹> --format lr|c1|lines [--scope all|picks|usable|client] [--ids a,b]
#   复制原片(只往 --dest 里写): LABELGUI_DATA_DIR=/tmp/lg LabelGUI --copy-originals <文件夹> --dest <目录> [--scope client] [--ids a,b]
# 批量页 / 连拍挑选 / 审片 / 检视器离屏快照(测试用): LABELGUI_DATA_DIR=/tmp/lg LabelGUI --batch-ui|--compare-ui <照片文件夹> out.png [--take 7] [--zoom [--person 1]] [--timeline-only --hover 3] [--review-ui|--inspector-ui --id DSCF7222] [--chapter 4] [--client-only] [--client-import-ui 回复.txt]
# 拼图出图(测试用): LabelGUI --collage <照片文件夹> --auto 6 --canvas 3:4 [--template 杂志|--style film] [--debug] --out a.jpg
#   [--look film|newsprint|contrastMono|muted|fineArt --harmonize 0.6] [--overlay masthead] [--scatter --frame polaroid]
#   [--sticker postmark@0.7,0.1,-8]（贴纸多了 barcode、greasePencil）
#   [--masthead 刊名 --issue 期号]（{masthead} {issue}；刊头空 = 标题转大写 / 拼音，期号空 = 页码）
#   模板总览: --template-sheet sheet.jpg [--only 手账]   色调总览: --look-sheet looks.jpg
# 相册出图(测试用): LabelGUI --collage <照片文件夹> --album --pdf --marks --out 目录
# 下面两个会改写拼图工程和设置，必须指定临时数据目录（不设直接拒绝运行）:
# 拼图编辑脚本(测试用): LABELGUI_DATA_DIR=/tmp/lg LabelGUI --collage-ops <照片文件夹> --ops "swap:00>11,move:010>11:left,lock:00,regen,undo" --out 目录
#   renderclean / renderexport 旁边总会写 .marks.json（水印、文字块 texts、每格取景 crops）；dumptexts 打印每页文字块；style:KEY / title:标题
#   masthead:刊头 / issue:期号 / kit:出一期（一键成套）/ pagelook:mono@0.6 / celllook:10=sepia / insets:上;下;内;外|none（每边 0…0.4）/
#   datevars:2026-10-23（星期、农历、干支）/ fonts（字体解析表）/ photofacts（托盘照片的帧号、场、判决…）/
#   toneprobe:/a.jpg;/b.jpg（亮度、黑白判定）。出图前都先等后台的路人信息算完（门禁不随机器快慢变）
#   一张照片多个字块：overlay:/anchor:/overlaypos:/overlaytext:/effect: 都可写 路径.第几块（00.1）；overlayadd:00=corner / overlaydel:00.1；
#   tset:目标=键=值;…（文字格路径 / 照片路径[.i] / itemN：rotation、ruleStyle、lineSpacing、L0.fitWidth、L0.textCase、body.columns…，
#   值里的逗号写 %2C）；anchor 多了 leftColumn / rightColumn / bottomBand（沿边找位置）
#   人物挡字 / 封面取景 / 抠图：overlayfront:00.0=off（字在人后）、depth:00=0.2（压字深度）、framing:00=cover、
#   cutout:00=on;白边;投影（cutoutdrag:00=白边;投影 = 拖滑杆的一格，连着拖记一步撤销）、itemcutout:N=on;白边;投影|off（散落相纸做成抠图贴纸）、
#   tset 多了 depth / maxOcclusion / occlusionRule=total（装饰大字只限总量）；coverdump（每格的取景、头顶、每块字被挡多少和原因）、
#   maskdump[:目录]（托盘每张的主体蒙版）、fakefaces:ID=x0;y0;x1;y1/…（合成人脸，验合影退让）。marks.json 的
#   texts[].occlusion、masks 记下遮挡量和决定（预览、导出同一个；刊头带着的小字行每行另限 15%，eyeFar = 眼睛离刊头远）；
#   --collage 多了 --overlay-behind（定死位置时「自动」取景换成「封面」，打印每块字的决定）/ --overlay-front
#   渲染件：halftone:dot|line[;点距;网角;锐度;网点增大;墨色;纸色|page] / halftone:none（照片加网，点距相对短边默认 0.004，
#   不到 3 像素只调影调不出点；page = 纸色跟页面（模糊 / 渐变底跟底色块），深色页配深墨时换成纸白；marks.json 的 halftone 记实际点距、出没出点、
#   墨色纸色）、border:mat=F6F1E7 / mat:0.07（卡纸边 + 细线）、
#   paperover:0.5（纸纹压在照片上）/ grain:0.4、sticker:barcode|greasePencil、itemmark:N=circle|cross|dot|cropLine、
#   itemcolor:N=C8302A、itemlabel:N=字（条码编的字）；色调多了 newsprint / contrastMono / muted / fineArt
#   印样 / 底片条：contact:135|645|66|67|auto[;每条帧数;条数;sheet|strip]（这一页改成印样，托盘按拍摄先后排成一卷）/ contact:off、
#   contactset:键=值;…（upright fill marks cross color roll note edge iso edgeprint jitter tilt margin circles gap…）、
#   contactmark:ID=circle|cross|dot|cropLine|none|auto、contactframes:ID;ID|tray、contactdump；marks.json 的 contactSheet 记帧号 ↔ 照片 id、记号；
#   整页水印在印样页上：开着「有留白时放在留白里」时签名和字放在片条外面的空纸上，放不下照旧排也不压片条（居中的照旧压在片子上）
#   托盘 / 批量页联动（核对托盘跟着刷新）：batchverdict:DSCF7207=pick|usable|reject（批量页手动改判）、reattach（切回拼图 tab）、
#   batchswitch（批量页重新载入这一场）、addfiles:/a.jpg;/b.jpg（托盘「添加文件…」）
# 主体蒙版 / 人物挡字自检（真照片那一半要先分析过，0 张算失败）:
#   LABELGUI_DATA_DIR=/tmp/lg LabelGUI --analyze <照片文件夹> && LABELGUI_DATA_DIR=/tmp/lg LabelGUI --mask-selftest <照片文件夹> [--dump 目录]
#   （真照片的蒙版耗时、头顶；合成数据验每条规则和退让；不给文件夹 = 只验合成数据；--dump 写字形轮廓和真画出来的墨的对照图）
# 一键成套出图(测试用): LabelGUI --collage <照片文件夹> --kit fashionIssue|contactRoll|weddingAlbum --out 目录/名.jpg（多页写 名_01…）
#   fashionIssue = 出一期（封面 + 3 张内页，3:4）[--cover-step 2]（封面用第 3 个主图候选，和「换封面」同一套候选）；
#   contactRoll = 按卷出印样（一个章节一卷，同一章节两台机身每台一卷；A4 300dpi，超过 35 帧分 ROLL n/2；每场最好的精选红圈、废片打叉）；
#   weddingAlbum = 整本婚礼相册。ops：kit:<成套>（先等路人信息算完）、nextcover[:N]（换封面：主图候选往后轮 N 张，只换封面那张）、
#   herodump（出一期挑封面的候选：按真套上封面的人物挡字打分，打印罚分和原因）
# 杂志风格(模板分类 时尚刊 / 底片印样 / 留白杂志 / 报纸风 / 瑞士网格 / 婚礼相册；--template-sheet sheet.jpg --only 时尚刊 看一类):
#   样式预设 --style（ops style:）fashion 时尚刊、minimal 留白杂志、newspaper 报纸（米色纸、圆点网 4.5‰、纸纹压照片）、swiss 瑞士、
#   weddingFineArt 婚礼 fine-art（象牙纸、自然白卡纸 + 细线、雅致色调）、weddingCanon 婚礼 · 古典版心；两个婚礼预设按册子尺寸重算边距
#   （max(12% 页边, 25mm)，自己改过边距的不动）
#   相册 --album-theme fineArt（婚礼 fine-art 编排：废片不要、同一场只留精选、扉页取宽景、每章疏 → 密 → 精选收尾、竖图成对、每跨页最多 3 张；
#   没给 --style 就用 fine-art 样式）[--no-chapter-mono]（一章黑白过三分之一也不整章转黑白）；ops albumtheme:classic|fineArt、chaptermono:on|off
#   界面：相册工具条「编排 默认 / 婚礼 fine-art」+「整章黑白」；fine-art 下没有「换一批」、没有备选（跨页按编排出版式）
#   模板「婚礼相册」5 款套用时按这本册子和这几张照片的横竖重排（配图、三联是一样大的窗口，横竖混排的对页双图两张同高）；
#   完整显示的照片卡纸贴着照片裁（裁切格整格是卡纸），印刷画布上细线离照片 4.5mm
#   占位符：{masthead_short}（没填刊头、标题转出来超过 12 个字母时截短：中文取前两个字的拼音）{initial}（刊头首字母）
#   {masthead_alt}（刊头和标题是同一串字时为空，否则 = 刊头）
#   {day_num} / {day_n}（不补零的日）{issue_n}（不补零的期号）{issue_cn}（第一期）{count_cn}（中文张数）{focal_mm}（实际焦距；
#   {focal} 是 35mm 等效）{fstop}（f/4.5）；{key|}（竖线后面空着）= 可省略：「 · 」隔开的一段这种占位符全空就连分隔点不印；
#   [[…]] 里有空的占位符整段不印，[[甲||乙]] = 甲不全印乙
#   tset 多的键：L<n>.spreadShort=on（短刊头加字距）、L<n>.accent=on（颜色从照片取）、L<n>.textCase=traditional|traditionalRTL（繁体 / 繁体右起）、
#   clearBottom=0.104（不进底部遮挡带）、scrim=off（干净的字，不垫雾面）、matchTone=on（同一格几块统一深浅）、fade=0.55（底部压暗）、
#   inkTop=0.025、maxZoom=1.6（封面取景最多拉近几倍）、tightEdge=on、ruleStyle=box（细线框）、body.balanced=1（平衡分栏）、
#   body.traditional=1；cutout:P=on[;白边;投影][;edge]（edge = 人得延伸到成品底边）；contactset 多了 paper=F6F5F1|page、choice=roll|best
#   正文在栏里排不下时字号一档档缩（最多缩到 75%，栏不动）；模板 JSON 里另有：行的 overflow=wrap|shrink（放不下时折行 /
#   只缩这一行）、onlyWhenFilled=键（这个占位符是空的就整行不印）、文字格的 paperTone（字跟着底色翻深浅：黑白字对比不到 3:1 翻，
#   强调色不翻成黑白，不够 4:1 的保持色相、调深浅到 4.5:1）
#   界面里有控件的：照片加网的网型 / 点距 / 网角 / 锐度 / 网点增大 / 墨色 / 纸色、四边边距（样式 › 留白与形状）、印样逐帧的记号 /
#   先后 / 移出（版式 › 印样 › 逐帧，同 contactmark / contactframes）；只在命令行和模板里改的（模板自己的微调，界面不放）：
#   tset 的 scrim / fade / matchTone / clearBottom / inkTop / maxZoom / tightEdge / spreadShort / accent、正文的 gap / weight
#   .marks.json：texts[].occlusion.eyeClamp、masks[].people（主体以外的人，照片坐标；maskdump 打印「别的人」）
#   套过固定比例模板（瑞士网格这种严格栅格）的页「存成模板」/ ops savetpl:，「套用时按照片比例自适应」默认关（存出来的比例不变）
# 杂志风格自检(都要临时数据目录；给照片文件夹的先 --analyze；全过退出 0):
#   LABELGUI_DATA_DIR=/tmp/lg LabelGUI --fashion-selftest [<照片文件夹>]（挑主图、出一期 4 页、换封面轮一圈、7 个模板字块不重叠不压脸不进遮挡带、
#     文案里没有真实刊名 / 胶片品牌；合成数据验合影、闭眼、路人、人物挡字退让；不给文件夹只跑合成那半）
#   --film-selftest <照片文件夹> [--out 目录]（按卷出印样对判决、合成三章节 92 帧、底片条挑帧、笔色、旧 JSON、整页水印不压片条）
#   --minimal-selftest [<照片文件夹>]（5 个模板 × 8 张：字号下限、字块不叠不压脸、预览和导出取景一样；不给文件夹只验名字、商标、字体、占位符）
#   --newspaper-selftest [<照片文件夹>]（简转繁、右起、默认字无真实刊名 / 刊号、缺 EXIF、竖排从右往左、细线框、网点点距、平衡分栏）
#   --swiss-selftest（栅格公式、5 个模板的栏线 / 基线格 / 字号 / 强调色、没有 EXIF、抠图贴底边；合成数据，不读照片、不写文件）
#   --album-selftest [<照片文件夹> --out 目录]（合成四章婚礼验 R1–R12、四种册子的版式、预设边距重算、模板重排；给了文件夹再出一本跨页图）
# 拼图门禁(本地跑，CI 不跑；逐像素和基线比): Scripts/collage_gate.sh <照片文件夹> <分析过的数据目录> <基线目录|-> <输出目录> [LabelGUI]
# 拼图界面离屏快照(测试用): LABELGUI_DATA_DIR=/tmp/lg LabelGUI --collage-ui <照片文件夹> out.png [--album] [--tab 文字] [--light]
#   [--select 路径 [--overlay-index N]]（选中照片上第 N 个字块）[--contact-frames]（印样的「逐帧」一开始就展开）
#   只截检视器: --inspector-width 300；--ax-dump 打印滑杆 / 分段控件的值；--notice "提示文字" 截图前放一条状态栏提示
# 水印页离屏快照(测试用): LABELGUI_DATA_DIR=/tmp/lg LabelGUI --watermark-ui <照片文件夹> out.png [--width 960] [--light] [--signature sig.png]
# 水印页批量导出(测试用，输出目录里已有同名的另存 -2、不覆盖): LABELGUI_DATA_DIR=/tmp/lg LabelGUI --watermark-batch <照片文件夹> <输出目录> [--signature sig.png] [--exif]
# 导出 JPG / 精华 Top N(测试用，只往 --dest 里写；没给的选项用界面的出厂默认，打印每个文件的尺寸/方向/GPS/色彩/字节数):
#   LABELGUI_DATA_DIR=/tmp/lg LabelGUI --export-jpeg <照片文件夹> --dest <目录> [--scope picks|picks+usable|top:20]
#   [--size original|4096|2048|moments|xhs|ig|long:N|short:N|box:WxH] [--sharpen off|std|high] [--color srgb|keep]
#   [--strip-gps|--keep-gps] [--name '{名次:2}_{原名}'] [--max-mb 2] [--quality 90] [--overwrite]
#   top:N 时 --dest 是「精华」那一层，里面每次新建 TopN_日期_时间
#   导出设置那一段的离屏快照: LABELGUI_DATA_DIR=/tmp/lg LabelGUI --batch-ui <照片文件夹> out.png --delivery-ui jpeg|highlights|watermark [--delivery-json '{"size":"short:1200"}']
# 给 AI agent 用（MCP，stdio；不开界面、不启动 app）: LabelGUI --mcp   （客户端配置见「给 AI 用（MCP）」）
#   app 开着：读当前场次、改判、套模板、一键成套等交给 app 执行，窗口里实时可见、可 ⌘Z（app 菜单「允许 AI 实时操作（MCP）」可关）
#   app 没开：只能看状态、列场次、列模板，其余工具回 app_not_running
#   打印工具定义: LabelGUI --mcp-tools
#   单次调用（调试用，和 --mcp 同一套分发；app 开着时一样交给 app）: LabelGUI --mcp-call app_status '{}'
#   MCP 这一层的自检（纯函数，不起服务器、不读写文件）: LabelGUI --mcp-selftest [--json]
#   冒烟（CI 也跑，不需要照片、不起宿主）: python3 -I Scripts/mcp_smoke.py .build/release/LabelGUI --ci
#   整窗离屏快照（测试用，窗口不显示）: LABELGUI_DATA_DIR=/tmp/lg LabelGUI --app-ui <照片文件夹> out.png [--tab 批量处理|水印|拼图|标注校准] [--size 1440x900] [--wait 4]
#   实时桥测试宿主（测试用，窗口不显示）: LABELGUI_DATA_DIR=/tmp/lg LABELGUI_LIVE_SOCK_ROOT=<短目录> LABELGUI_LIVE_TEST_OUT=<快照目录> LabelGUI --live-host <照片文件夹> [--size 1440x900] [--tab 批量处理|水印|拼图|标注校准] [--no-view]
#   实时桥冒烟（CI 也跑；本地真照片: --photos <照片文件夹> --data <分析过的数据目录>）: python3 -I Scripts/live_smoke.py .build/release/LabelGUI --ci
```

## 使用流程

1. 插上存储卡点「导入」（或打开 app → 选择照片文件夹 / 把文件夹拖进窗口）→ 自动**开始分析**
2. 拖动「筛选严格度」预设或滑杆，实时看废片/可用/精选分布
3. （可选）启动 VLM 服务 → 对幸存照片跑语义复核
4. 按分组视图里过连拍：点「开始挑选」（或按 **C**），一组一组点要留的那张，⏎ 确认自动跳下一组
5. 审片模式（F）逐张过一遍，键盘 1/2/3/0 改判
6. 导出 → 写 XMP 进 LR/C1 精修，或直接导出 JPG / 选片确认表
7. （可选）网格多选后点「拼图」，或在拼图 tab 带精选进来：自动排版出九宫格/小红书拼图，或切到相册模式编排印刷跨页；也可以「一键成套」出一期杂志、一卷印样或一本婚礼相册
8. 确认无误后把废片移到废纸篓

## 给 AI 用（MCP）

app 里的程序本身就是一个 MCP 服务器（`LabelGUI --mcp`，stdio），Claude Code、Antigravity 这类 AI agent 接上以后能看你的选片结果、替你改判、排拼图。**这一版只做实时**：你开着 app 时，AI 读的是 app 当前打开的那一场（app 内存里的状态，含还没存盘的改动），改判、套模板、一键成套、换封面、改字、换样式、撤销都交给 app 自己执行，你在窗口里当场看到，⌘Z 照样能撤；app 没开时只能看状态、列场次、列模板，其余工具一律回 `app_not_running`，请你自己打开 app —— **MCP 绝不会替你启动 app**。app 没开时读场次、出拼图成品图，以及让 AI 分析新文件夹，这一版都没有。

### 18 个工具

app 没开时也能用的只有前 3 个；其余 15 个要 app 开着、而且 `session` 是 app 当前打开的那一场（不是就回 `session_not_open`，要换场次用 `app_open_session`）。

| # | 工具 | 做什么 | app 没开时 |
|---|---|---|---|
| 1 | `app_status` 状态自检 | 版本、数据目录、app 开没开、能不能实时操作（`live.state`）、app 当前打开的场次（`live.open_session`）和页、各种上限。AI 第一个调它 | 能用 |
| 2 | `cull_list_sessions` 列出已分析的场次 | 侧栏「最近场次」里的场次（最多 15 场）：照片文件夹、张数、在不在线、是不是在受保护位置、是不是 app 当前打开的那一场 | 能用 |
| 3 | `collage_list_templates` 拼图模板与成套 | 内置模板（分类、照片格数、要几张横图竖图）、一键成套、样式、色调、画布能填的值 | 能用 |
| 4 | `cull_session_overview` 场次概览 | 精选 / 可用 / 废片各多少张、废片理由、阈值、章节、场和近似重复、还没处理的场、多机身对时 | `app_not_running` |
| 5 | `cull_list_photos` 列照片 | 按条件列照片，每张一行（判决、理由、时间、场、锐度、人脸和闭眼……），分页 | `app_not_running` |
| 6 | `cull_get_photos` 照片详情 | 1–20 张的完整分析：EXIF、每张脸的位置和睁闭眼、复审结果、人工改判和客户选中 | `app_not_running` |
| 7 | `cull_list_groups` 分组 | 章节、场（一串连拍，带名次和推荐的那张）、近似重复组的成员 | `app_not_running` |
| 8 | `cull_preview_photos` 看照片 | 1–4 张缩小预览（内联图片）；`crop=face` 从原图按主脸裁一块放大，看眼睛和对焦，和连拍挑选里的放大同一个算法 | `app_not_running` |
| 9 | `collage_get_state` 看 app 里的拼图 | 拼图工程的状态（模式、页、模板、样式、文字、每个格子、撤销深度、`digest`）和 app 当前画面的预览 | `app_not_running` |
| 10 | `app_open_session` 在 app 里打开场次 | = 侧栏「最近场次」里点它。只能开列表里的；会清掉 app 里这一场的撤销记录，撤销栈不空时先回 `confirm_required` 让 AI 问你 | `app_not_running` |
| 11 | `cull_set_verdicts` 改判 | = 网格里按 1/2/3/0（精选 / 可用 / 废片 / 恢复自动），一次调用一步撤销 | `app_not_running` |
| 12 | `cull_show_photos` 在 app 里定位照片 | 在网格里选中这些照片、把焦点移过去给你看，默认把 app 切到批量页（不拉到前台）；不改判决、不进撤销、不改你的筛选 | `app_not_running` |
| 13 | `collage_apply_template` 套模板 | = 检视器里点模板；模板全名、分类名、名字里的几个字都认 | `app_not_running` |
| 14 | `collage_run_kit` 在 app 里一键成套 | 出一期 / 按卷出印样 / 整本婚礼相册，替换当前拼图，一步撤销（最长约 50 秒） | `app_not_running` |
| 15 | `collage_next_cover` 换封面 | 「出一期」换下一张封面，内页不动 | `app_not_running` |
| 16 | `collage_set_text` 改标题/刊头/期号/文字 | 标题、副标题、刊头、期号，或者某个格子里某块字的第一行；几个字段一起改也是一步撤销 | `app_not_running` |
| 17 | `collage_set_style` 换样式/色调 | 样式预设、统一色调和强度 | `app_not_running` |
| 18 | `app_undo` 撤销 AI 刚做的一步 | 只撤 AI 自己的那一步（`target` 分 `verdicts` / `collage`）；你之后又改过就不撤（`undo_not_ours`），请你自己 ⌘Z | `app_not_running` |

改判和拼图写的结果里有 `live.notice`（和窗口里那一页状态栏上同一句话）、这一步怎么撤，拼图写还带 app 当前画面的预览图。设了 `LABELGUI_MCP_LIVE=0` 时只注册前 3 个。

### 安全承诺

- **不启动 app，不开任何窗口**：`--mcp` 进程不建应用对象、不起任何子进程，找 app 只是连本机的一个 Unix socket（连不上就是没开）；没有 `open`、Apple Events、URL scheme。它跑着的时候程序坞上不会多出图标。唯一可能冒出来的框不是它开的：它自己万一崩了，系统会弹「"选片工具"意外退出」，别点「重新打开」（见排错）。
- **不读照片**：`--mcp` 自己不打开任何照片和预览图。AI 看到的图都是 app 出的（在主线程以外解码、裁切、压成 JPEG），经本机通道发过来。`--mcp` 在数据目录里只读 `sessions.json` 和锁文件 `.live.lock`。
- **不写数据目录和设置**：`--mcp` 不往数据目录、照片文件夹、任何设置里写一个字节；在从没开过 app 的机器上也不会建出数据目录。它唯一会写的是预览输出目录（默认 `~/Pictures/xuanpian-mcp`，`LABELGUI_MCP_OUT` 可以换）：根上一个 `.xuanpian-mcp` 标记文件，加上 `previews/` 里给 AI 看过的图，按内容各存一份（文字结果里给路径，图太大被客户端截掉时 AI 还能按路径读），7 天以前的、或者总量超过 1 GB 时最旧的自动删，只删它自己起名的文件；第一次存图时才建这个目录。
- **改动全是 app 自己做的**：和你点按钮调的是同一个方法，进 app 自己的撤销记录，AI 的一次调用就是一步 ⌘Z，存盘也照常由 app 做。app 不会被拉到前台、不抢键盘焦点、不弹窗。读工具不改判决和拼图；和界面一样会顺带写盘的只有两处：`collage_get_state` 会像你切到拼图页那样把这一场的拼图工程接上（可能存一次拼图工程），`collage_set_style` 和在检视器里点样式预设一样，会改「下次新建拼图沿用的默认样式」。
- **受系统隐私保护的位置不碰**：照片在桌面、文稿、下载、`~/Library`（含 iCloud 云盘、各家网盘）、外置盘和存储卡（`/Volumes`）、网络卷（`/Network`、`/net`）、照片图库（`.photoslibrary`）里的场次，`--mcp` 只按路径字符串认出来，连「文件夹在不在」都不查。AI 不能把 app 切到这些场次（回 `protected_location`），要你自己在侧栏「最近场次」里点开；点开以后读和改照常，只是看照片只用 1024 的预览、不读原图（`crop=face` 也是在预览上裁，细节有限，结果里会写明）。为的是 AI 的操作不会让系统以终端或 app 的名义弹出隐私授权框。
- **桥只对本机同一个用户开放**：app 和 `--mcp` 之间是本用户临时目录里的一个 Unix socket（目录 0700、socket 0600），不开任何网络端口；连进来的不是同一个用户的进程就拒绝。
- **AI 看到的东西会发给 AI 的服务商**：上面说的都是 app 和 `--mcp` 之间这一段。AI 看过的预览图、脸部裁块，以及文件名和路径、EXIF、人脸位置、判决这些文字结果，会由你的 AI 客户端（Claude Code、Antigravity……）和对话一起发给它背后的模型服务（Anthropic、Google 等），和你在对话里发照片一样。照片不能离开这台 Mac 的话，就别接云端的 AI。

### 在 app 里看得到什么

**标题栏**：窗口标题「选片工具」后面的副标题，四个 tab 都在，不压任何内容。不用 AI 时什么都不显示，窗口和以前一模一样。

| 什么时候 | 标题栏上 |
|---|---|
| 没有 AI 来过，或者菜单里关了 | 什么都不显示 |
| 2 分钟内有 AI 来过 | 「Claude Code 已连接」（客户端报的名字是 claude-ai 时写「Claude 已连接」，别的写「AI 已连接」），到点自己淡掉 |
| AI 的一步正在执行 | 「AI 正在操作：套模板…」（一键成套、换封面在等 app 算路人信息的时候就已经显示） |
| 刚做完（10 秒） | 和那一页状态栏上同一句话，比如「AI：改了标题 · 在拼图页 ⌘Z 撤销」 |
| 另一个选片工具占着同一个数据目录 | 「另一个选片工具正在用这个数据目录：AI 只连那一个」 |
| 数据目录的锁被别的程序拿走了 | 「数据目录的锁被别的程序拿走了：AI 实时操作已停，重开 app 恢复」（一直留着；AI 收到 `app_unreachable`，锁刚被放掉的那一秒里也可能看到 `not_running` / `old_app`） |
| 实时连接开不起来 | 「AI 实时操作的连接开不起来（原因）：已暂停，每 10 秒自动再试」，开好了自己消失；再试也没用的几种写「…：已停，重开 app 再试」 |

**菜单开关**：「选片工具」菜单里带勾的「允许 AI 实时操作（MCP）」，默认开，只记在这台 Mac 的 app 设置里。关掉以后 AI 的读和改都回 `bridge_off`（AI 会告诉你是在菜单里关的），标题栏不再显示 AI，app 照常用；状态自检、列场次、列模板照常。关之前已经开始的那一步（比如正在算的一键成套）照样做完，⌘Z 能撤；排在后面的都不做。再勾上就恢复。

**你在操作时 AI 等你（`user_busy`）**：
- 你正按着鼠标、拖动、在输入框里打字（含输入法拼字）、开着菜单、在拼图里拖缝拖字时，AI 的改动最多等 2 秒，你一停手就执行；2 秒后还在忙就不执行，回 `user_busy`（`transient:true`），AI 过几秒再试。
- 开着对话框或面板（确认框、导出、对时、导入客户选择……）、在连拍挑选里、在拼图里裁切、拼图正在导出时不等，立刻回 `user_busy`（`transient:false`），AI 会请你先关掉；审片模式开着时只挡切场次和定位照片，改判照常（画面上那张的判决当场变）。照片检视器开着时改判挡不挡，要在真 app 上确认。
- 读不等，随时能读。

### 配置

前提：app 已经装在「应用程序」里，而且正常打开过一次。从 Release 下载的 app 带隔离属性，没打开过就让 AI 客户端直接起里面的程序，系统可能拦下来（按 Gatekeeper 的机制推断，没验证过）：先照「安装」第 2 步打开一次，或者 `xattr -dr com.apple.quarantine /Applications/选片工具.app`。

**Claude Code**（在终端里执行一次，之后每个项目都能用）：

```bash
claude mcp add --scope user --env LABELGUI_NO_GUI=1 --transport stdio xuanpian -- "/Applications/选片工具.app/Contents/MacOS/LabelGUI" --mcp
# 或者给单个项目用：在项目根目录的 .mcp.json 里加 "timeout":120000（毫秒）
# 想让模型能按路径打开成品：启动时加 --add-dir ~/Pictures/xuanpian-mcp，或者在设置里放行 Read(//Users/<你>/Pictures/xuanpian-mcp/**)
```

`--env` 和服务器名 `xuanpian` 中间必须隔一个别的选项（这里是 `--transport stdio`）：紧跟在 `--env` 后面的名字会被当成另一个 `KEY=value`。`command` 指向 app 里的程序最稳；指向自己构建的 `.build/release/LabelGUI` 也能连同一个 app，只是 `app_status` 里多一条 `build_mismatch` 警告。app 升级以后先重开 app，再在 Claude Code 里用 `/mcp` 重连。

**Antigravity**：配置文件是 `~/.gemini/config/mcp_config.json`（官方 MCP 页的写法；早期教程写的是 `~/.gemini/antigravity/mcp_config.json`，哪个对还没验证），只给某个工作区用就写 `<工作区>/.agents/mcp_config.json`。**不要**写 `type` 字段，`command` 用绝对路径；文件里已经有别的服务器的话，把 `xuanpian` 这一项加进已有的 `mcpServers`，别整个覆盖：

```json
{"mcpServers":{"xuanpian":{"command":"/Applications/选片工具.app/Contents/MacOS/LabelGUI","args":["--mcp"],"env":{"LABELGUI_NO_GUI":"1"},"timeoutSeconds":120}}}
```

CLI ≥1.1.16 也可以用 `agy mcp add`。Codex 要把 `tool_timeout_sec` 设到 ≥60；Cursor 要写 `"type":"stdio"`。

**路径里的中文**（「选片工具」）在 Antigravity、Codex 上能不能正常启动还没验证。起不来就改用一个 ASCII 路径的包装脚本（`chmod +x` 以后，把配置里的 `command` 换成它的绝对路径 `/Users/<你>/bin/xuanpian-mcp`（JSON 配置里不认 `~`），`args` 里的 `--mcp` 去掉：脚本已经带了）：

```sh
#!/bin/sh
# ~/bin/xuanpian-mcp
exec "/Applications/选片工具.app/Contents/MacOS/LabelGUI" --mcp "$@"
```

用包装脚本，不用软链接：通过软链接启动时，程序认不认得出自己在 app 里没验证过。

### 审批

Claude Code 交互模式下，每个工具第一次调用都会问你。建议 9 个读工具（第 1–9 个）和 8 个写工具（第 11–18 个）选「以后不再问」：写的改动当场出现在你眼前、一步 ⌘Z 能撤。**`app_open_session` 保持每次问**：切场次会清掉 app 里这一场的判决和拼图撤销记录。想一次配好，在 Claude Code 的设置（`~/.claude/settings.json`，或者项目里的 `.claude/settings.json`）里放行这 17 个（合并进文件里已有的 `permissions.allow`，别整个文件覆盖）：

```json
{"permissions":{"allow":[
  "mcp__xuanpian__app_status", "mcp__xuanpian__cull_list_sessions", "mcp__xuanpian__collage_list_templates",
  "mcp__xuanpian__cull_session_overview", "mcp__xuanpian__cull_list_photos", "mcp__xuanpian__cull_get_photos",
  "mcp__xuanpian__cull_list_groups", "mcp__xuanpian__cull_preview_photos", "mcp__xuanpian__collage_get_state",
  "mcp__xuanpian__cull_set_verdicts", "mcp__xuanpian__cull_show_photos", "mcp__xuanpian__collage_apply_template",
  "mcp__xuanpian__collage_run_kit", "mcp__xuanpian__collage_next_cover", "mcp__xuanpian__collage_set_text",
  "mcp__xuanpian__collage_set_style", "mcp__xuanpian__app_undo"
]}}
```

`--allowedTools "mcp__xuanpian__*"`（或 `mcp__xuanpian`）会连 `app_open_session` 一起放行，只建议在验收脚本里用。Antigravity 默认每次都问；写 `mcp(xuanpian/*)` 同样会把 `app_open_session` 一起放行，由你自己决定。审批框停多久都不要紧：AI 的这一步从你点允许那一刻才开始计时；停着的时候你改过拼图的话，带 `if_digest` 的拼图改动会被挡下来（`stale_digest`），不会盖掉你的改动。

### 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `LABELGUI_DATA_DIR` | 不设（`~/Library/Application Support/选片工具`） | 换数据目录，测试用。**MCP 配置里别设**：设了以后 MCP 找的是那个目录的锁和连接，和你开着的 app 对不上，app 明明开着却是 `not_running` |
| `LABELGUI_MCP_OUT` | `~/Pictures/xuanpian-mcp` | 预览存在哪（绝对路径），只用里面的 `previews/`。空目录、或者带 `.xuanpian-mcp` 标记的目录才用（不空又没标记的不用，免得清理删到你的文件）；不能在受保护位置、数据目录、照片文件夹里。不能用时图照常内联、带一条警告（`inline:false` 时回 `output_dir_unusable`） |
| `LABELGUI_MCP_DEADLINE_SEC` | 50 | `deadline_seconds` 的上限（秒，5–600）。只有看照片（默认 30）、一键成套和换封面（默认 50）三个工具有这个参数；只管 AI 传了的 `deadline_seconds`，没传时照用 30 / 50 秒；其余读写都是 10 秒 |
| `LABELGUI_MCP_INLINE_KB` | 600 | 一次调用里内联图片的合计上限（KB，最大 20000）；超了的那几张不给图，标 `truncated:true` |
| `LABELGUI_MCP_TEXT_MAX` | 20000 | 文字结果的长度上限（字符，1000–1000000；小于 1000 按默认）；超了就少给几条、标 `truncated:true`（列照片、分组带 `next_cursor` 接着翻） |
| `LABELGUI_MCP_LIVE` | 不设（开） | `0` = 只注册 app 没开也能用的 3 个工具，从不连 app：保证 AI 碰不到开着的 app |
| `LABELGUI_NO_GUI` | 不设 | `1` = 这个进程绝不开界面，命令行里没有无头参数就直接退出。上面的配置都带着它 |
| `LABELGUI_ALLOW_GUI` | 不设 | `1` = 父进程不是 launchd、stdin 又不是终端时也允许开界面（从 Xcode、IDE、脚本里开 app 时用，见排错） |

`LABELGUI_LIVE_SOCK_ROOT`、`LABELGUI_LIVE_TEST_*` 只给测试宿主 `--live-host` 用，不要写进 MCP 配置。

### 排错

- **先看 `app_status`**：`live.state` 说明 app 那边是什么情况，`warnings` 里每条都带 `hint`。`--mcp` 的日志写在 stderr，在客户端的 MCP 日志里看。

  | `live.state` | 意思 | 怎么办 |
  |---|---|---|
  | `live` | 能实时操作 | — |
  | `not_running` | app 没开（或者这台机器上还没开过 app、数据目录不存在） | 自己打开 app；MCP 不会替你开 |
  | `bridge_off` | 菜单里关了「允许 AI 实时操作（MCP）」 | 勾上 |
  | `unreachable` | app 开着，连不上它的实时桥（socket 被系统清掉还没自愈、锁被别的程序拿走、桥开不起来） | 看标题栏上那句；一般 10 秒内自己恢复，不行就重开 app |
  | `unresponsive` | app 开着，1 秒内没回应（卡住了） | 看一下 app，过一会儿再试 |
  | `proto_mismatch` | app 和 MCP 的实时桥版本对不上 | 重开 app；还不行就是两边差太多，更新 app |
  | `old_app` | 开着的是还没有实时桥的旧版 | 更新 app；标题栏写着「数据目录的锁被别的程序拿走了…」的话，重开 app 就行 |
  | `not_ready` | app 正在启动或者正在退出 | 过几秒再试 |
  | `data_dir_mismatch` | 连上的 app 用的不是同一个数据目录 | 重开 app；MCP 配置里别设 `LABELGUI_DATA_DIR` |
  | `peer_rejected` | 桥的另一头不是你这个用户的进程 | 看看是不是别的账户开着选片工具 |
  | `disabled` | 设了 `LABELGUI_MCP_LIVE=0` | 去掉它，重连 MCP |

- **app 明明开着却是 `not_running`**：多半是 MCP 配置的 `env` 里设了 `LABELGUI_DATA_DIR`（比如照抄了「从源码构建」里的调试写法）。`app_status` 里 `data_dir_override` 是 `true` 就是这个原因，去掉它再重连。另一种：标题栏写着「数据目录的锁被别的程序拿走了…」，退出并重开 app。再一种：`warnings` 里是 `data_dir_missing`、可数据目录其实在，是宿主的沙箱连目录都不让看（见下面「宿主的沙箱」）。
- **改动「没出现」**：看结果里的 `live.window_state`：`hidden`（⌘H 隐藏了）、`minimized`（最小化了）、`occluded`（被挡住了或者在别的桌面上）、`no_window`（app 开着但没有窗口）。这时改动已经生效并存盘，切过去就能看到；AI 不会替你把窗口拉出来。
- **一直 `user_busy`**：`transient:false` 是开着对话框、面板、连拍挑选、裁切或者正在导出，关掉就好；`transient:true` 是你正在拖动或打字，停手几秒。
- **`protected_location`**：那一场的照片在受保护位置（见安全承诺），这一版没有放行开关：自己在侧栏「最近场次」里点开它，之后 AI 照常读和改。
- **超时**：最长的一步（一键成套）在 50 秒以内，客户端的超时要比它长：Claude Code 项目级 `.mcp.json` 的 `"timeout":120000`、Antigravity 的 `timeoutSeconds:120`、Codex 的 `tool_timeout_sec`（≥60）。app 主线程正忙、读超时回 `deadline_exceeded`，过一会儿再调；写到一半超时或者断了回 `app_outcome_unknown`，AI 用结果里的 `op_id` 原样再调同一个工具，不会做两遍。
- **图片和 `MAX_MCP_OUTPUT_TOKENS`**：Claude Code 默认把一次工具结果限制在 25000 token（`MAX_MCP_OUTPUT_TOKENS`）。在 Claude Code 2.1.312 上实测，内联图片不算进这个上限：1 张 1024、4 张 768、1 张 1568、2 张 1568（一次 523 KB，base64 约 70 万字符）、4 张脸部裁块、一张 768 的拼图预览都完整送到了模型，所以默认内联、一次合计 600 KB。这只是这一版 Claude Code 上测出来的，换了版本或客户端要是图被截掉、报结果太大：让 AI 用 `inline:false`（只给 `previews/` 里的文件路径，再按路径读），或者把 `LABELGUI_MCP_INLINE_KB` 调小；文字被截时启动 Claude Code 前设 `MAX_MCP_OUTPUT_TOKENS=50000`，或者把 `LABELGUI_MCP_TEXT_MAX` 调小让列表分页。
- **按路径读预览**：Claude Code 默认只读工作目录里的文件。要让模型按 `file` 路径读预览，启动时加 `--add-dir ~/Pictures/xuanpian-mcp`，或者在设置里放行 `Read(//Users/<你>/Pictures/xuanpian-mcp/**)`。
- **宿主的沙箱**：宿主（比如 Antigravity 的终端沙箱）不让读 `~/Library/Application Support` 或者本用户临时目录里的 socket 时，app 开着，`app_status` 却报 `data_dir_unreadable`、`unreachable`；沙箱连目录在不在都不让看时，报的是 `data_dir_exists:false`、`data_dir_missing` 和 `not_running`，看着像 app 没开。都是在宿主里放行。
- **弹出「"选片工具"意外退出」**：app 窗口还在、或者 app 本来就没开的话，崩了（或者被强行结束）的是 AI 客户端起的 `--mcp` 进程（它是 app 里的程序，系统按 app 报）。这时点「忽略」，**不要点「重新打开」**：那会把 app 打开。然后在客户端里重连 MCP（Claude Code 用 `/mcp`）。
- **从 Xcode / IDE 里开 app 直接退出**：父进程不是 launchd（访达、程序坞、启动台、`open` 打开的都是）、stdin 又不是终端时（Xcode 的 Run、IDE、调试器、某些脚本和启动器里常常是这样），app 会当成是被 MCP 客户端起的，不开界面、退出码 2，stderr 写「像是被 MCP 客户端启动的…」。真要开界面就设 `LABELGUI_ALLOW_GUI=1`（Xcode：Edit Scheme › Run › Arguments › Environment Variables）。访达、程序坞、启动台、`open` 打开的，终端里直接跑的都不受影响。

## 关键技术决策记录

- **锐度量纲**：Tenengrad（RMS Sobel 梯度）值域与拉普拉斯方差完全不同，清晰照片实测约 65-95，预设按此标定
- **小脸免疫**：人脸面积 < 0.3% 画面时关闭闭眼判定（3072 分析图上 landmark 不可靠），实测正常环境人像在 0.4-1.5%。合影例外：小脸在原图分辨率上重量 EAR，免检线放到 0.05%（4000 万像素原图上这么大的脸和分析图上 0.3% 的脸像素一样多）；只给「像主体」的小脸做（不小于最大脸的一半，或者没有哪张脸独大的合影里有 ≥3 张差不多大的），没有这种脸的照片不解原图、不多花时间
- **曝光看主体**：裁切和欠曝 / 过曝都看人不看背景 —— 裁切数「脸扩到头 + 上半身（2 倍脸宽、往下 3 个脸高）」里的像素（这块不到画面 2% 时——远景里的小人——照旧数整张，碰巧认出一张小脸不该把大片死白天空排除在外），亮度看脸的中位数；欠曝还要求整张最亮的 1% 也不亮（p99 < 100），只看脸会冤枉深肤色和背光。线性光压暗实测：-2EV 脸 86–88、p99 116–120 不判，-3EV 脸 61–62、p99 83–86 判
- **VLM 提示词纪律**：不在提示词里列举示例物体（小模型会复读式幻觉"找到"它们）；远景路人明确不算抢镜；模型对场景的判断只能提示、不能否决
- **质量分**：连拍组内相对比较（低于组内最高 0.15 才嫌疑），单张按景别补偿（脸越小阈值越宽）
- **MCP 自己写，不用官方 Swift SDK**：SDK 的 stdio 传输在两个以上的大结果（>约 120 KB）同时回时帧会写乱（压测 66 个请求一个完整的都没有），而 Claude Code 正好会并行调只读工具、预览图又都比这大；手写版同样压测 0 损坏。仓库没有外部包，手写版二进制只多 72 KB，SDK 版多约 5 MB、还会把 CI 的 Swift 下限钉在 6.1。SDK 修好这些以后只换协议那一层（`MCP/MCPStdio.swift`）
- **app 开着时由 app 执行，MCP 只转发**：app 每次整份重写自己的文件、从不回读，外面直接改盘会被 app 下一次保存悄悄盖掉，也进不了撤销记录；所以 app 是唯一写者，AI 的改动走 app 自己的方法、压 app 自己的撤销栈（一次调用一步 ⌘Z）。通道是本用户的 Unix socket，每次调用连一次：不开网络端口（localhost TCP 会弹防火墙框、拿不到对端是谁，浏览器也能打进来），connect 拉不起任何进程；不用 XPC（具名服务要 launchd 管，按需启动就是把 app 拉起来）和 Apple Events（会弹自动化授权框，还会把没开的 app 启动起来）
