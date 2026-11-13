const T = require('../playground/tern.js');
const src = require('fs').readFileSync(0, 'utf8');
try { T.load(src, { assets: ['mountains', 'sunset', 'avatar', 'logo'], libraries: JSON.parse(process.env.TERN_LIBS || '{}'), components: JSON.parse(process.env.TERN_COMPS || '{}') }); console.log(JSON.stringify({ ok: true })); }
catch (e) { console.log(JSON.stringify({ ok: false, phase: e.phase, msg: e.msg, pos: e.pos, file: e.file })); }
