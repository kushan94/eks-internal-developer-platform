// Renders the template's skeletons the way Backstage's fetch:template does:
// Nunjucks with ${{ }} for variables, applied to file paths and contents.
const nunjucks = require('nunjucks');
const fs = require('fs'), path = require('path');
const env = new nunjucks.Environment(null, { tags: { variableStart: '${{', variableEnd: '}}' }, autoescape: false });
const [,, skeleton, out, valuesJson] = process.argv;
const values = JSON.parse(valuesJson);
const walk = d => fs.readdirSync(d, { withFileTypes: true }).flatMap(e => e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]);
for (const f of walk(skeleton)) {
  const rel = env.renderString(path.relative(skeleton, f), { values });
  const dest = path.join(out, rel);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(dest, env.renderString(fs.readFileSync(f, 'utf8'), { values }));
  console.log(rel);
}
