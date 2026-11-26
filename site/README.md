# wb.hackmo.net 官网

纯静态，无构建、无依赖。三个文件：

- `index.html` —— 页面本身，CSS 与 JS 都内联引用外部 `site.css`
- `site.css` —— 全部样式，深色单一强调色
- `icon-512.png` / `shot-app.jpg` / `apple-touch-icon.png` —— 图

部署：`./deploy/deploy-site.sh`（会 rsync 到 `/var/www/wb/` 并重载 nginx）。

改样式直接改 `site.css`，没有打包步骤。注意 `shot-app.jpg` 是从
`assets/shots/app-main.jpg` 压出来的，重截截图后要同步替换。
