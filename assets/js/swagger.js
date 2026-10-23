// Entry of the API documentation page (/swaggerui), bundled apart from app.js
// so the dashboard stays light. The Swagger UI release is vendored in
// assets/vendor (see assets/vendor/README.md); importing its CSS makes esbuild
// emit priv/static/assets/js/swagger.css next to swagger.js.
import SwaggerUIBundle from "../vendor/swagger-ui-bundle.js"
import "../vendor/swagger-ui.css"

const root = document.getElementById("swagger-ui")

if (root) {
  SwaggerUIBundle({
    url: root.dataset.specUrl,
    domNode: root,
    deepLinking: true,
    presets: [SwaggerUIBundle.presets.apis],
  })
}
