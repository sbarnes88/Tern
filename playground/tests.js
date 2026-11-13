const assert = require('assert');
const T = require('./tern.js');
const { EXAMPLES } = require('./examples.js');
const ex = id => EXAMPLES.find(e => e.id === id).src;

let passed = 0, failed = 0;
function test(name, fn) {
  try { fn(); passed++; } catch (e) { failed++; console.log('FAIL', name, '\n   ', e.message); }
}
const page = (body, decls = '') => T.load(`page "t"\n${decls}\nview {\n${body}\n}`);
const text = p => T.renderText(p.render()).join('\n');
const errOf = src => { try { T.load(src); } catch (e) { return e; } throw new Error('expected an error'); };
function search(nodes, pred) {
  for (const n of nodes) {
    if (pred(n)) return n;
    if (n.children) { const r = search(n.children, pred); if (r) return r; }
  }
  return null;
}
function findBtn(nodes, label) {
  const r = search(nodes, n => n.t === 'button' && n.label === label);
  if (!r) throw new Error('no button ' + label);
  return r;
}
function findIn(nodes, name) {
  const r = search(nodes, n => n.t === 'input' && n.name === name);
  if (!r) throw new Error('no input ' + name);
  return r;
}
const click = (p, label, times = 1) => { for (let i = 0; i < times; i++) findBtn(p.render(), label).click(); };
const type = (p, name, v) => findIn(p.render(), name).set(v);
function expectErr(src, phase, needle) {
  const e = errOf(src);
  assert.strictEqual(e.phase, phase, `phase of: ${e.message}`);
  assert(e.msg.includes(needle), `message "${e.msg}" should include "${needle}"`);
  return e;
}

// ---- carried over from 0.1
test('text + int', () => { const e = expectErr('state n: Int = 1\nview { text "a" + n }', 'type error', 'toText'); assert.strictEqual(e.pos[0], 2); });
test('wrong state init', () => expectErr('state n: Int = "x"\nview { }', 'type error', 'needs Int'));
test('assign wrong type', () => expectErr('state n: Int = 1\nview { button "b" -> n = "no" }', 'type error', 'needs Int'));
test('unknown name', () => expectErr('view { text missing }', 'type error', 'unknown name'));
test('if needs bool', () => expectErr('view { if 1 { text "x" } }', 'type error', 'needs Bool'));
test('missing return', () => expectErr('fn f(): Int { }\nview { }', 'type error', 'must return Int'));
test('return wrong type', () => expectErr('fn f(): Int { return "s" }\nview { }', 'type error', 'needs Int'));
test('arg count/type', () => {
  expectErr('fn f(a: Int) { }\nview { button "b" -> f() }', 'type error', 'takes 1');
  expectErr('fn f(a: Int) { }\nview { button "b" -> f("x") }', 'type error', 'needs Int');
});
test('empty list needs type', () => expectErr('view { for x in [] { text "hi" } }', 'type error', 'empty list'));
test('foreach is an alias for for', () => {
  expectErr('view { foreach x in [] { text "hi" } }', 'type error', 'empty list');
  const p = page('foreach i in range(3) { button toText(i) -> total = total + i }\ntext toText(total)', 'state total: Int = 0');
  click(p, '2');
  assert.strictEqual(p.render().slice(-1)[0].text, '2');
});
test('mixed list', () => expectErr('state xs: List<Int> = [1, "a"]\nview { }', 'type error', 'needs Int'));
test('input needs Text state', () => expectErr('state n: Int = 0\nview { input n }', 'type error', 'Text state'));
test('compare different types', () => expectErr('view { if 1 == "a" { text "x" } }', 'type error', 'cannot compare'));
test('syntax errors', () => {
  expectErr('view { text "unterminated }', 'syntax error', 'unterminated');
  expectErr('view { text }', 'syntax error', 'expression');
  expectErr('state x: Double = 1\nview { }', 'syntax error', 'unknown type');
  expectErr('text "a"', 'syntax error', 'expected');
  expectErr('page "x"', 'syntax error', 'no view');
});
test('expression statement', () => expectErr('view { button "b" -> 1 + 2 }', 'type error', 'does nothing'));

test('counter clicks', () => {
  const p = T.load(ex('counter'));
  assert(text(p).includes('Count: 0'));
  click(p, '+', 2);
  assert(text(p).includes('Count: 2') && text(p).includes('Even.'));
  click(p, 'Step 5'); click(p, '-');
  assert(text(p).includes('Count: -3') && text(p).includes('Below zero.'));
  click(p, 'Reset');
  assert(text(p).includes('Count: 0'));
});
test('todo add/remove', () => {
  const p = T.load(ex('todo'));
  type(p, 'draft', '  buy milk '); click(p, 'Add');
  const t = text(p);
  assert(t.includes('3. buy milk') && t.includes('3 item(s)'));
  assert.strictEqual(p.state.draft, '');
  click(p, 'Done', 3);
  assert(text(p).includes('All done!'));
});
test('welcome greeting', () => {
  const p = T.load(ex('welcome'));
  assert(text(p).includes('Type your name'));
  type(p, 'name', 'Sam');
  assert(text(p).includes('Hello, Sam!'));
});
test('quiz run', () => {
  const p = T.load(ex('quiz'));
  type(p, 'guess', '4'); click(p, 'Submit');
  type(p, 'guess', 'paris'); click(p, 'Submit');
  type(p, 'guess', 'no'); click(p, 'Submit');
  const t = text(p);
  assert(t.includes('Score: 2 out of 3') && t.includes('The answer was yes.'), t);
  click(p, 'Play again');
  assert(text(p).includes('Question 1'));
});
test('functions, recursion, scopes', () => {
  const p = page('text toText(fact(5))', 'fn fact(n: Int): Int { if n <= 1 { return 1 } return n * fact(n - 1) }');
  assert.strictEqual(p.render()[0].text, '120');
});
test('closures capture loop var', () => {
  const p = page('for i in range(3) { button toText(i) -> total = total + i * 10 }\ntext toText(total)', 'state total: Int = 0');
  click(p, '2'); click(p, '1');
  assert.strictEqual(p.render().pop().text, '30');
});
test('runtime errors', () => {
  let p = page('button "go" -> n = 1 / zero\ntext toText(n)', 'state n: Int = 0\nstate zero: Int = 0');
  assert.throws(() => click(p, 'go'), e => e.phase === 'runtime error' && e.msg.includes('division by zero'));
  p = page('button "go" -> n = xs[5]', 'state n: Int = 0\nstate xs: List<Int> = [1]');
  assert.throws(() => click(p, 'go'), e => e instanceof T.TernError);
});
test('deep recursion reported, not crashed', () => {
  const p = page('button "go" -> n = f(1)', 'state n: Int = 0\nfn f(x: Int): Int { return f(x + 1) }');
  assert.throws(() => click(p, 'go'), e => e instanceof T.TernError && e.msg.includes('recursed'));
});
test('int division floors, modulo is non-negative', () => {
  assert.strictEqual(page('text toText(7 / 2) + " " + toText(7 % 2) + " " + toText(-3 + 1) + " " + toText(-7 / 2)').render()[0].text, '3 1 -2 -4');
});
test('builtins', () => {
  assert.strictEqual(page('text upper("a\\tb") + join(["x", "y"], ",") + toText(contains("hello", "ell"))').render()[0].text, 'A\tBx,ytrue');
  const p = page('text toText(setAt([1, 2, 3], 1, 9)[1])');
  assert.strictEqual(p.render()[0].text, '9');
});
test('else-if chain', () => {
  const p = page('if n == 1 { text "one" } else if n == 2 { text "two" } else { text "many" }', 'state n: Int = 2');
  assert.strictEqual(p.render()[0].text, 'two');
});

// ---- new in 0.2: styles
test('size/bold/italic/color on text', () => {
  const n = page('text "hi" size 20 bold italic underline color red').render()[0];
  assert.deepStrictEqual(n.style, { size: 20, bold: true, italic: true, underline: true, color: '#d1242f' });
});
test('hex colours incl. shorthand, rgb()', () => {
  const n = page('text "a" color #fff background #0B57D0\ntext "b" color rgb(1, 300, -5)').render();
  assert.strictEqual(n[0].style.color, '#ffffff'); assert.strictEqual(n[0].style.background, '#0b57d0');
  assert.strictEqual(n[1].style.color, '#01ff00');
});
test('flags with when', () => {
  const p = page('text "a" bold when on\ntext "b" bold when !on', 'state on: Bool = true');
  const r = p.render();
  assert.strictEqual(r[0].style.bold, true); assert.strictEqual(r[1].style.bold, false);
});
test('dynamic size, clamped', () => {
  const p = page('text "a" size n', 'state n: Int = 500');
  assert.strictEqual(p.render()[0].style.size, 96);
  p.state.n = 1; assert.strictEqual(p.render()[0].style.size, 6);
});
test('named styles + explicit override', () => {
  const p = page('text "a" style loud size 10\ntext "b" size 10 style loud', 'style loud { size 30 bold color red }');
  const r = p.render();
  assert.strictEqual(r[0].style.size, 10); assert.strictEqual(r[0].style.bold, true);
  assert.strictEqual(r[1].style.size, 30);   // later style wins
});
test('multiple styles in order', () => {
  const p = page('text "a" style a b', 'style a { color red bold }\nstyle b { color blue }');
  assert.deepStrictEqual(p.render()[0].style, { color: '#0b57d0', bold: true });
});
test('style props that do not apply are ignored', () => {
  const p = page('button "go" style s -> n = 1\nrow style s { text "x" }', 'state n: Int = 0\nstyle s { align center size 30 background red padding 9 }');
  const r = p.render();
  assert.deepStrictEqual(r[0].style, { size: 30, background: '#d1242f', padding: 9 });
  assert.deepStrictEqual(r[1].style, { align: 'center', background: '#d1242f', padding: 9 });   // a row now takes align (its items)
});
test('style errors', () => {
  expectErr('view { button "b" align center -> n = 1 }\nstate n: Int = 0', 'type error', "a button cannot have 'align'");
  expectErr('view { text "x" size "big" }', 'type error', 'needs Int');
  expectErr('view { text "x" color 5 }', 'type error', 'needs Color');
  expectErr('view { text "x" align red }', 'type error', 'needs Align');
  expectErr('view { text "x" style nope }', 'type error', "unknown style 'nope'");
  expectErr('style a { bold }\nstyle b { style a }\nview { }', 'type error', 'cannot use another style');
  expectErr('style a { bold }\nstyle a { italic }\nview { }', 'type error', 'defined twice');
  expectErr('view { row size 3 { text "x" } }', 'type error', "a row cannot have 'size'");
  expectErr('style s { size "x" }\nview { }', 'type error', 'needs Int');
  expectErr('view { text "x" bold when 1 }', 'type error', 'needs Bool');
});
test('Color and Align are real types', () => {
  const p = page('text "a" color tint align side', 'state tint: Color = purple\nstate side: Align = center');
  assert.deepStrictEqual(p.render()[0].style, { color: '#8250df', align: 'center' });
  expectErr('state c: Color = "red"\nview { }', 'type error', 'needs Color');
  expectErr('state c: Color = red\nview { button "b" -> red = blue }', 'type error', 'built in');
  expectErr('view { text "x" + red }', 'type error', 'cannot be used');
  assert.strictEqual(page('text toText(red == #d1242f)'.replace('toText(red == #d1242f)', '"x"') + '\nif red == #d1242f { text "same" }').render()[1].text, 'same');
});
test('hex literal must be 3 or 6 digits', () => expectErr('view { text "x" color #12 }', 'syntax error', 'unexpected character'));

// ---- new in 0.2: para, bullet, table
test('para spans inherit paragraph style', () => {
  const n = page('para size 18 color blue { span "a " span "b" bold span "c" color red }').render()[0];
  assert.deepStrictEqual(n.spans.map(s => s.text), ['a ', 'b', 'c']);
  assert.deepStrictEqual(n.spans[0].style, { size: 18, color: '#0b57d0' });
  assert.deepStrictEqual(n.spans[1].style, { size: 18, color: '#0b57d0', bold: true });
  assert.strictEqual(n.spans[2].style.color, '#d1242f');
});
test('para only accepts spans', () => expectErr('view { para { text "x" } }', 'syntax error', 'span'));
test('bullet', () => assert.strictEqual(page('bullet "a" bold').render()[0].t, 'bullet'));
test('table renders header and rows', () => {
  const p = T.load(ex('table'));
  const tb = p.render().find(n => n.t === 'table');
  assert.deepStrictEqual(tb.header, ['Item', 'Price', 'Qty', 'Subtotal']);
  assert.deepStrictEqual(tb.rows[0], ['Tea', '$3', '2', '$6']);
  assert(text(p).includes('Total: $25'));
  click(p, '+ Tea');
  assert.deepStrictEqual(p.render().find(n => n.t === 'table').rows[0], ['Tea', '$3', '3', '$9']);
});
test('table without header, with if', () => {
  const p = page('table { cells "a", "b"\n if on { cells "c", "d" } else { cells "e", "f" } }', 'state on: Bool = false');
  const tb = p.render()[0];
  assert.strictEqual(tb.header, null); assert.deepStrictEqual(tb.rows, [['a', 'b'], ['e', 'f']]);
});
test('table column count and order errors', () => {
  expectErr('view { table { header "a", "b"\n cells "x" } }', 'type error', '1 cell(s) but the table has 2');
  expectErr('view { table { cells "x"\n header "x" } }', 'type error', 'header');
  expectErr('view { table { header 1, "b" } }', 'type error', 'needs Text');
  expectErr('view { table { text "x" } }', 'syntax error', "inside a table");
});
test('table height gives a scrolling box; other properties are errors', () => {
  const p = page('table height 120 { header "a", "b"\n cells "x", "y" }');
  const tb = p.render()[0];
  assert.strictEqual(tb.style.height, 120); assert.deepStrictEqual(tb.rows, [['x', 'y']]);
  assert.strictEqual(page('table { cells "x" }').render()[0].style.height, undefined);
  expectErr('view { table width 100 { cells "x" } }', 'type error', "a table cannot have 'width'");
  expectErr('view { table height "tall" { cells "x" } }', 'type error', 'needs Int');
});
test('table cells can be buttons and links, and can span columns', () => {
  const p = page(`table padding 3 background #eef {
  header button "Sort" -> n = n + 1, "Name" bold, "Info"
  cells "Total" span 2, link "go" to "other.tern"
  for i in range(2) { cells "x", button "+" -> n = n + 10, toText(i) color red }
}`, 'state n: Int = 0');
  const tb = p.render()[0];
  assert.strictEqual(tb.style.padding, 3);
  assert.deepStrictEqual(tb.header, ['Sort', 'Name', 'Info']);
  assert.deepStrictEqual(tb.rows[0], ['Total', '', 'go']);
  assert.strictEqual(tb.body[0].cells[0].span, 2);
  assert.strictEqual(tb.body[0].cells[1].kind, 'link'); assert.strictEqual(tb.body[0].cells[1].target, 'other.tern');
  assert.strictEqual(tb.body[1].cells[2].style.color, '#d1242f'); assert.strictEqual(tb.hrow.cells[1].style.bold, true);
  tb.hrow.cells[0].click(); tb.body[2].cells[1].click();
  assert(text(p).includes('Sort'));
  assert.strictEqual(p.state.n, 11);
  expectErr('view { table { header "a", "b"\n cells "x" span 3 } }', 'type error', '3 cell(s) but the table has 2');
  expectErr('view { table { cells "x" span 0 } }', 'type error', 'at least 1');
  expectErr('view { table { cells "x" span two } }', 'syntax error', "after 'span'");
  expectErr('view { table { cells button 1 -> n = 1 } }', 'type error', 'needs Text');
  expectErr('view { table { cells "x" height 4 } }', 'type error', "cannot have 'height'");
});
test('slice, sort, sortOrder and reverse', () => {
  const p = page('text toText(len(a))', `state a: List<Int> = [5, 3, 9, 3]
state t: List<Text> = ["pear", "Apple", "fig"]
state f: List<Float> = [2.5, 1.5]
state r: List<Int> = sortOrder(a)
state s: List<Int> = slice(a, 1, 3)
state big: List<Int> = slice(a, 2, 99)
state none: List<Int> = slice(a, 3, 1)
state neg: List<Int> = slice(a, -5, 2)
state so: List<Int> = sort(a)
state rv: List<Int> = reverse(a)
state tt: List<Text> = sort(t)
state ff: List<Float> = sort(f)`);
  const S = p.state;
  assert.deepStrictEqual(S.r, [1, 3, 0, 2]);          // ties keep their original order
  assert.deepStrictEqual(S.s, [3, 9]); assert.deepStrictEqual(S.big, [9, 3]);
  assert.deepStrictEqual(S.none, []); assert.deepStrictEqual(S.neg, [5, 3]);
  assert.deepStrictEqual(S.so, [3, 3, 5, 9]); assert.deepStrictEqual(S.rv, [3, 9, 3, 5]);
  assert.deepStrictEqual(S.tt, ['Apple', 'fig', 'pear']); assert.deepStrictEqual(S.ff, [1.5, 2.5]);
  assert.deepStrictEqual(S.a, [5, 3, 9, 3]);          // the original list is unchanged
  expectErr('state b: List<Bool> = [true]\nview { text toText(len(sort(b))) }', 'type error', 'List of Int, Float or Text');
  expectErr('view { text toText(len(slice([1], "a", 2))) }', 'type error', 'needs Int');
  expectErr('view { text toText(len(slice(3, 0, 1))) }', 'type error', 'needs a List');
});
test('checkbox edits a Bool state, or runs an action', () => {
  const p = page(`checkbox on "Notify me" bold
checkbox flags[1] "Second" -> flags = setAt(flags, 1, !flags[1])
table { cells checkbox flags[0] "cell" -> flags = setAt(flags, 0, !flags[0]), "x" }`, 'state on: Bool = false\nstate flags: List<Bool> = [false, false]');
  let r = p.render();
  assert.strictEqual(r[0].t, 'checkbox'); assert.strictEqual(r[0].label, 'Notify me'); assert.strictEqual(r[0].checked, false);
  assert.strictEqual(r[0].style.bold, true);
  r[0].click(); r[1].click(); r[2].body[0].cells[0].click();
  r = p.render();
  assert.strictEqual(r[0].checked, true); assert.strictEqual(r[1].checked, true);
  assert.strictEqual(r[2].body[0].cells[0].checked, true); assert.strictEqual(r[2].body[0].cells[0].kind, 'checkbox');
  assert(text(p).includes('[x] Notify me'), text(p));
  expectErr('state n: Int = 0\nview { checkbox n "x" }', 'type error', 'needs Bool');
  expectErr('state on: Bool = false\nview { checkbox !on "x" }', 'type error', 'must name a Bool state');
  expectErr('state on: Bool = false\nview { checkbox on "x" width 4 }', 'type error', "cannot have 'width'");
});
test('data table example sorts both ways and pages without repeating', () => {
  const p = T.load(ex('datatable'));
  const names = () => p.render().find(n => n.t === 'table').rows.map(r => r[1]).filter(x => x && !x.startsWith('Picked'));
  const head = i => p.render().find(n => n.t === 'table').hrow.cells[i].click();
  const btn = l => p.render().find(n => n.t === 'row').children.find(c => c.label === l).click();
  assert.deepStrictEqual(names(), ['Cupcake', 'Donut', 'Eclair', 'Froyo']);
  head(2); assert.deepStrictEqual(names(), ['Froyo', 'Ice cream', 'Eclair', 'Cupcake']);
  head(2); assert.deepStrictEqual(names(), ['KitKat', 'Donut', 'Honeycomb', 'Jelly bean']);   // descending
  assert(p.render().find(n => n.t === 'table').hrow.cells[2].text.includes('\u25bc'));
  head(3); assert.deepStrictEqual(names(), ['Jelly bean', 'Honeycomb', 'Cupcake', 'Froyo']);   // new column starts ascending
  const labels = () => p.render().find(n => n.t === 'row').children.map(c => c.label).filter(Boolean);
  assert(!labels().includes('Previous') && labels().includes('Next'));                         // no Previous on page 1
  btn('Next'); btn('Next');
  assert.deepStrictEqual(names(), ['KitKat']);                                                 // last page, nothing repeated
  assert(labels().includes('Previous') && !labels().includes('Next'));                         // no Next on the last page
  btn('Previous'); btn('Previous');
  assert.deepStrictEqual(names(), ['Jelly bean', 'Honeycomb', 'Cupcake', 'Froyo']);
});
test('text boxes edit list items and struct fields, also inside tables', () => {
  const p = page(`for i in range(len(names)) { input names[i] placeholder "name" }
for i in range(len(people)) { input people[i].name }
table { for i in range(len(names)) { cells input names[i], toText(i) } }`, `state names: List<Text> = ["a", "b"]
struct P { name: Text  age: Int }
state people: List<P> = [P(name: "x", age: 1)]`);
  const find = (nodes, f) => nodes.filter(f);
  let r = p.render();
  assert.deepStrictEqual(r.filter(n => n.t === 'input').map(n => n.value), ['a', 'b', 'x']);
  r[1].set('B!'); r[2].set('Xavier');
  r = p.render();
  assert.deepStrictEqual(r.filter(n => n.t === 'input').map(n => n.value), ['a', 'B!', 'Xavier']);
  assert.strictEqual(p.state.people[0].age, 1);
  const tb = r.find(n => n.t === 'table');
  assert.strictEqual(tb.body[1].cells[0].kind, 'input'); assert.strictEqual(tb.body[1].cells[0].text, 'B!');
  tb.body[0].cells[0].set('first');
  assert.deepStrictEqual(p.state.names, ['first', 'B!']);
  assert(text(p).includes('[_first_]'), text(p));
  expectErr('state n: List<Int> = [1]\nview { input n[0] }', 'type error', 'input can only edit Text');
  expectErr('state n: List<Text> = ["a"]\nview { for s in n { input s } }', 'type error', 'is not a state');
  expectErr('struct P { name: Text }\nstate ps: List<P> = [P(name: "a")]\nview { for p in ps { input p.name } }', 'type error', 'copy of a list item');
  expectErr('view { input 5 }', 'syntax error', 'input edits a Text state');
});
test('table resizable, in any order with style words', () => {
  assert.strictEqual(page('table { cells "a" }').render()[0].resizable, false);
  for (const head of ['resizable', 'resizable height 100', 'height 100 resizable', 'padding 4 resizable height 90']) {
    const tb = page(`table ${head} { cells "a" }`).render()[0];
    assert.strictEqual(tb.resizable, true, head);
  }
  expectErr('state resizable: Int = 1\nview { text "x" }', 'syntax error', 'resizable');
});
test('modal draws only while its Bool is true, and closes itself or runs its action', () => {
  const p = page(`button "Open" -> open = true
modal open width 300 radius 4 {
  heading "Sure?"
  button "Yes" -> { n = n + 1 open = false }
}
modal n > 5 -> n = 0 { text "Big" }`, 'state open: Bool = false\nstate n: Int = 0');
  let r = p.render();
  assert.deepStrictEqual(r.map(x => x.t), ['button']);
  r[0].click(); r = p.render();
  assert.deepStrictEqual(r.map(x => x.t), ['button', 'modal']);
  assert.strictEqual(r[1].style.width, 300); assert.strictEqual(r[1].style.radius, 4);
  assert.deepStrictEqual(r[1].children.map(x => x.t), ['heading', 'button']);
  assert(text(p).includes('[modal]') && text(p).includes('[/modal]'), text(p));
  r[1].close(); r = p.render();                                    // closing a bare-state modal sets it false
  assert.strictEqual(p.state.open, false); assert.deepStrictEqual(r.map(x => x.t), ['button']);
  r[0].click(); p.render()[1].children[1].click(); assert.strictEqual(p.state.n, 1);
  p.state.n = 9; r = p.render();                                   // an expression modal closes with its action
  assert.strictEqual(r[r.length - 1].t, 'modal'); r[r.length - 1].close();
  assert.strictEqual(p.state.n, 0);
  expectErr('state o: Bool = false\nview { row { modal o { text "x" } } }', 'type error', 'directly in the view');
  expectErr('state o: Bool = false\nview { modal o { modal o { text "x" } } }', 'type error', 'directly in the view');
  expectErr('state n: Int = 0\nview { modal n { text "x" } }', 'type error', 'needs Bool');
  expectErr('state o: Bool = false\nview { modal !o { text "x" } }', 'type error', 'must name a Bool state');
  expectErr('state o: Bool = false\nview { modal o height 4 { text "x" } }', 'type error', "cannot have 'height'");
});
test('layout: gap, margin, grow, widths, align and grid', () => {
  const p = page(`row gap 20 align spread margin 4 { text "a" grow 2 maxwidth 300 minwidth 50
  button "b" grow 1 margin 2 -> n = 1 }
column gap 0 align center maxwidth 500 { image "logo" margin 6 grow 1 }
grid 3 gap 12 padding 8 { text "1"
  text "2" }
grid n { text "x" }
text "t" margin 100 grow 99 maxwidth 5000`, 'state n: Int = 99', { assets: ['logo'] });
  const r = p.render();
  assert.deepStrictEqual(r[0].style, { gap: 20, align: 'spread', margin: 4 });
  assert.deepStrictEqual(r[0].children[0].style, { grow: 2, maxwidth: 300, minwidth: 50 });
  assert.deepStrictEqual(r[0].children[1].style, { grow: 1, margin: 2 });
  assert.deepStrictEqual(r[1].style, { gap: 0, align: 'center', maxwidth: 500 });
  assert.strictEqual(r[2].t, 'grid'); assert.strictEqual(r[2].cols, 3);
  assert.deepStrictEqual(r[2].style, { gap: 12, padding: 8 }); assert.strictEqual(r[2].children.length, 2);
  assert.strictEqual(r[3].cols, 12);                                           // clamped to 1..12
  assert.deepStrictEqual(r[4].style, { margin: 64, grow: 12, maxwidth: 2000 });  // clamped
  assert(text(p).includes('<grid 3>'), text(p));
  expectErr('view { text "x" gap 4 }', 'type error', "a text cannot have 'gap'");
  expectErr('view { grid 2 align center { text "x" } }', 'type error', "a grid cannot have 'align'");
  expectErr('view { button "b" maxwidth 5 -> back }', 'type error', "a button cannot have 'maxwidth'");
  expectErr('view { grid "two" { text "x" } }', 'type error', 'needs Int');
  expectErr('view { row { grid 2 { modal on { text "x" } } } }\nstate on: Bool = false', 'type error', 'directly in the view');
  expectErr('state grid: Int = 1\nview { text "x" }', 'syntax error', 'grid');
});
test('select and radio edit a Text place from a list of options', () => {
  const p = page(`select shade in colors placeholder "Pick" width 200
radio plan in ["Free", "Pro"] color red
for i in range(len(people)) { select people[i].role in roles }
table { for i in range(len(people)) { cells select people[i].role in roles placeholder "role", "x" } }`,
`state colors: List<Text> = ["Red", "Green"]
state shade: Text = "Green"
state plan: Text = "Pro"
state roles: List<Text> = ["admin", "user"]
struct P { name: Text  role: Text }
state people: List<P> = [P(name: "a", role: "user"), P(name: "b", role: "")]`);
  let r = p.render();
  assert.strictEqual(r[0].t, 'select'); assert.strictEqual(r[0].value, 'Green'); assert.deepStrictEqual(r[0].options, ['Red', 'Green']);
  assert.strictEqual(r[0].placeholder, 'Pick'); assert.strictEqual(r[0].style.width, 200);
  assert.strictEqual(r[1].t, 'radio'); assert.deepStrictEqual(r[1].options, ['Free', 'Pro']); assert.strictEqual(r[1].value, 'Pro');
  assert.strictEqual(r[1].style.color, '#d1242f');
  r[0].set('Red'); r[1].set('Free'); r[3].set('admin');
  r = p.render();
  assert.strictEqual(p.state.shade, 'Red'); assert.strictEqual(p.state.plan, 'Free');
  assert.strictEqual(p.state.people[1].role, 'admin'); assert.strictEqual(p.state.people[1].name, 'b');
  const tb = r.find(n => n.t === 'table');
  assert.strictEqual(tb.body[0].cells[0].kind, 'select'); assert.deepStrictEqual(tb.body[0].cells[0].options, ['admin', 'user']);
  tb.body[0].cells[0].set('admin'); assert.strictEqual(p.state.people[0].role, 'admin');
  const t = text(p);
  assert(t.includes('[select: Red]') && t.includes('(x) Free') && t.includes('( ) Pro'), t);
  expectErr('state n: Int = 0\nview { select n in ["a"] }', 'type error', 'select can only edit Text state');
  expectErr('state c: Text = ""\nview { select c in [1, 2] }', 'type error', 'the options of a select needs List<Text>');
  expectErr('state c: Text = ""\nview { radio c in "abc" }', 'type error', 'the options of a radio needs List<Text>');
  expectErr('state c: Text = ""\nview { select c ["a"] }', 'syntax error', "'in'");
  expectErr('struct P { name: Text }\nstate ps: List<P> = [P(name: "a")]\nview { for p in ps { radio p.name in ["a"] } }', 'type error', 'copy of a list item');
  expectErr('state c: Text = ""\nview { radio c in ["a"] placeholder "x" }', 'syntax error', '');
  expectErr('state c: Text = ""\nview { select c in ["a"] bold }', 'type error', "a select cannot have 'bold'");
  expectErr('view { select 5 in ["a"] }', 'syntax error', 'select edits a Text state');
});
test('textarea, slider and disabled', () => {
  const p = page(`textarea notes placeholder "Notes" height 120 width 300
slider level in 0 to 10 width 200
slider low in 5 to 1
input name disabled when locked width 150
button "Go" disabled when locked -> n = n + 1
checkbox flag "f" disabled when locked
select pick in ["a", "b"] disabled when locked
radio pick in ["a", "b"] disabled
table { cells button "t" disabled -> n = n + 100 }`, `state notes: Text = "ab"
state level: Int = 99
state low: Int = 0
state name: Text = ""
state n: Int = 0
state flag: Bool = false
state pick: Text = ""
state locked: Bool = true`);
  let r;
  assert.throws(() => p.render(), /this slider ends \(1\) before it starts \(5\)/);
  p.state.low = 7; r = null;
  const p2 = page(`textarea notes placeholder "Notes" height 120 width 300
slider level in 0 to 10 width 200
slider levels[1] in 0 to 3
input name disabled when locked width 150
button "Go" disabled when locked -> n = n + 1
checkbox flag "f" disabled when locked
select pick in ["a", "b"] disabled when locked
radio pick in ["a", "b"] disabled
table { cells button "t" disabled -> n = n + 100 }`, `state notes: Text = "ab"
state level: Int = 99
state levels: List<Int> = [1, 9]
state name: Text = ""
state n: Int = 0
state flag: Bool = false
state pick: Text = ""
state locked: Bool = true`);
  r = p2.render();
  assert.strictEqual(r[0].t, 'textarea'); assert.strictEqual(r[0].value, 'ab'); assert.strictEqual(r[0].style.height, 120);
  assert.strictEqual(r[1].t, 'slider'); assert.strictEqual(r[1].value, 10);   // 99 is shown clamped into 0..10
  assert.strictEqual(r[1].lo, 0); assert.strictEqual(r[1].hi, 10); assert.strictEqual(p2.state.level, 99);
  assert.strictEqual(r[2].value, 3);
  r[0].set('x\ny'); r[1].set(4); r[2].set(2);
  assert.strictEqual(p2.state.notes, 'x\ny'); assert.strictEqual(p2.state.level, 4); assert.deepStrictEqual(p2.state.levels, [1, 2]);
  for (const n of r.slice(3, 8)) assert.strictEqual(n.style.disabled, true, n.t);
  r[3].set('typed'); r[4].click(); r[5].click(); r[6].set('a'); r[7].set('b'); r.find(n => n.t === 'table').body[0].cells[0].click();
  assert.strictEqual(p2.state.name, ''); assert.strictEqual(p2.state.n, 0); assert.strictEqual(p2.state.flag, false);
  assert.strictEqual(p2.state.pick, '');                                            // a disabled control does nothing
  p2.state.locked = false; r = p2.render();
  assert.strictEqual(r[3].style.disabled, false);
  r[3].set('typed'); r[4].click(); r[5].click(); r[6].set('a');
  assert.strictEqual(p2.state.name, 'typed'); assert.strictEqual(p2.state.n, 1); assert.strictEqual(p2.state.flag, true); assert.strictEqual(p2.state.pick, 'a');
  assert(text(p2).includes('[textarea: x]') && text(p2).includes('[slider: 4 in 0..10]'), text(p2));
  expectErr('state s: Text = ""\nview { slider s in 0 to 5 }', 'type error', 'slider can only edit Int state');
  expectErr('state n: Int = 0\nview { slider n in "a" to 5 }', 'type error', 'needs Int');
  expectErr('state n: Int = 0\nview { slider n in 0 }', 'syntax error', "'to'");
  expectErr('state n: Int = 0\nview { textarea n }', 'type error', 'textarea can only edit Text state');
  expectErr('view { slider 5 in 0 to 1 }', 'syntax error', 'slider edits an Int state');
  expectErr('state s: Text = ""\nview { textarea s bold }', 'type error', "a textarea cannot have 'bold'");
  expectErr('view { text "x" disabled }', 'type error', "a text cannot have 'disabled'");
  expectErr('state s: Text = ""\nview { input s height 4 }', 'type error', "an input cannot have 'height'");
});
test('saved state is restored when it still fits its type', () => {
  const decls = `struct P { name: Text  age: Int }
saved state n: Int = 1
saved state xs: List<Text> = ["a"]
saved state who: List<P> = []
saved state f: Float = 0.5
saved state c: Color = red
saved state ok: Bool = false
state temp: Int = 7`;
  const body = 'text "x"';
  const first = page(body, decls);
  assert.deepStrictEqual(first.savedNames, ['n', 'xs', 'who', 'f', 'c', 'ok']);
  first.state.n = 5; first.state.xs = ['q', 'r']; first.state.who = [{ name: 'Z', age: 3 }]; first.state.temp = 99; first.state.ok = true;
  const json = first.savedJSON();
  assert(!json.includes('temp'), json);                                    // only saved states
  const second = T.load(`page "t"\n${decls}\nview {\n${body}\n}`, { saved: JSON.parse(json) });
  assert.strictEqual(second.state.n, 5); assert.deepStrictEqual(second.state.xs, ['q', 'r']);
  assert.deepStrictEqual(second.state.who, [{ name: 'Z', age: 3 }]); assert.strictEqual(second.state.ok, true);
  assert.strictEqual(second.state.temp, 7);                                // not saved: starts fresh
  assert.strictEqual(second.state.f, 0.5); assert.strictEqual(second.state.c, '#d1242f');
  // values that do not fit the declared type are ignored
  const bad = { n: 'five', xs: [1], who: [{ name: 'Z' }], f: 'x', c: 'red', ok: 1 };
  const third = T.load(`page "t"\n${decls}\nview {\n${body}\n}`, { saved: bad });
  assert.strictEqual(third.state.n, 1); assert.deepStrictEqual(third.state.xs, ['a']); assert.deepStrictEqual(third.state.who, []);
  assert.strictEqual(third.state.f, 0.5); assert.strictEqual(third.state.c, '#d1242f'); assert.strictEqual(third.state.ok, false);
  const extra = T.load(`page "t"\n${decls}\nview {\n${body}\n}`, { saved: { who: [{ name: 'a', age: 1, evil: 2 }], n: 1.5, __proto__: { n: 3 } } });
  assert.deepStrictEqual(extra.state.who, []); assert.strictEqual(extra.state.n, 1);
  assert.strictEqual(page(body, 'state z: Int = 1').savedJSON(), null);   // nothing saved
  const big = page(body, 'saved state t: Text = ""'); big.state.t = 'x'.repeat(70000);
  assert.strictEqual(big.savedJSON(), null); assert.strictEqual(big.savedTooBig, true);
  expectErr('saved view { text "x" }', 'syntax error', "expected 'use'");
  expectErr('saved state n: Int = 1\nsaved state n: Int = 2\nview { text "x" }', 'type error', 'twice');
});
test('every gives the host timer nodes, with limits', () => {
  const p = page(`every 1000 when running -> secs = secs + 1
every 5 -> secs = secs + 100
text toText(secs)
for i in range(6) { every 2000 -> secs = secs + 1 }
modal open { every 500 -> secs = secs + 1000 }
every 100 + 400 when secs >= 0 -> { secs = secs + 10000 }`, 'state running: Bool = false\nstate secs: Int = 0\nstate open: Bool = false');
  let r = p.render(), timers = p.timers;
  assert.deepStrictEqual(timers.map(t => t.ms), [100, 2000, 2000, 2000]);       // first is off; 5 ms is raised to 100; at most 4
  timers[0].tick(); timers[1].tick(); assert.strictEqual(p.state.secs, 101);
  p.state.running = true; p.state.secs = 0; r = p.render(); timers = p.timers;
  assert.deepStrictEqual(timers.map(t => t.ms), [1000, 100, 2000, 2000]);
  timers[0].tick(); assert.strictEqual(p.state.secs, 1);
  assert(r.every(n => n.t !== 'timer'), 'timers are not drawn');
  // a timer that keeps failing stops after 3 errors
  const q = page('every 100 -> n = n / z\ntext "x"', 'state n: Int = 1\nstate z: Int = 0');
  q.render(); let t = q.timers[0];
  for (let i = 0; i < 2; i++) assert.throws(() => t.tick(), /division by zero/);
  assert.throws(() => t.tick(), /stopped after 3 errors/);
  q.render(); assert.strictEqual(q.timers.length, 0);
  q.state.z = 1; q.render(); assert.strictEqual(q.timers.length, 0);   // stays stopped
  expectErr('view { every "soon" -> back }', 'type error', 'needs Int');
  expectErr('state n: Int = 0\nview { every 100 when n -> back }', 'type error', 'needs Bool');
  expectErr('state n: Int = 0\nview { every 100 -> n = "a" }', 'type error', 'needs Int');
  expectErr('view { every 100 back }', 'syntax error', "'->'");
});
test('plain text view', () => {
  const t = text(T.load(ex('article')));
  assert(t.includes('| Type') && t.includes('* Tables, lists'), t);
});
test('all examples load; only broken fails', () => {
  for (const e of EXAMPLES) {
    if (e.id === 'broken') assert.throws(() => T.load(e.src, { libraries: e.libs }), x => x instanceof T.TernError);
    else T.load(e.src, { libraries: e.libs }).render();
  }
});

// ================= 0.3 =================
const txt1 = (body, decls = '') => page(body, decls).render()[0].text;

// ---- Float
test('float literals and arithmetic', () => {
  assert.strictEqual(txt1('text toText(1.5 + 2.25) + " " + toText(3.0 * 2.0) + " " + toText(7.0 / 2.0) + " " + toText(1.0 - 0.25)'), '3.75 6.0 3.5 0.75');
});
test('float toText hides binary noise', () => assert.strictEqual(txt1('text toText(0.1 + 0.2)'), '0.3'));
test('float comparisons and unary minus', () => {
  assert.strictEqual(txt1('text toText(-2.5 < 1.0) + toText(2.0 == 2.0) + toText(-1.5 * 2.0)'), 'truetrue-3.0');
});
test('Int and Float never mix silently', () => {
  expectErr('state n: Int = 1\nview { text toText(n + 1.5) }', 'type error', 'cannot mix Int and Float');
  expectErr('state x: Float = 1\nview { }', 'type error', 'needs Float but this is Int');
  expectErr('view { text toText(5.0 % 2.0) }', 'type error', "'%' only works on Int");
  expectErr('view { text toText(1.5 < 2) }', 'type error', 'cannot mix');
});
test('float conversion helpers', () => {
  assert.strictEqual(txt1('text toText(toFloat(3) / 2.0)'), '1.5');
  assert.strictEqual(txt1('text toText(round(2.5)) + toText(round(2.4)) + toText(floor(2.9)) + toText(ceil(2.1))'), '3223');
  assert.strictEqual(txt1('text fixed(3.14159, 2) + " " + fixed(2.0, 3) + " " + fixed(0.005, 1)'), '3.14 2.000 0.0');
  assert.strictEqual(txt1('text toText(sqrt(2.25))'), '1.5');
  expectErr('view { text toText(round(3)) }', 'type error', 'needs Float');
});
test('parse text to numbers safely', () => {
  assert.strictEqual(txt1('text toText(toIntOr(" 42 ", 0)) + toText(toIntOr("4x", -1)) + toText(toFloatOr("2.5", 0.0)) + toText(toFloatOr("", 9.5))'), '42-12.59.5');
});
test('float division by zero and sqrt of negative are runtime errors', () => {
  let p = page('button "go" -> r = 1.0 / z\ntext fixed(r, 1)', 'state r: Float = 0.0\nstate z: Float = 0.0');
  assert.throws(() => click(p, 'go'), e => e.phase === 'runtime error' && /division/.test(e.msg));
  p = page('button "go" -> r = sqrt(0.0 - 4.0)', 'state r: Float = 0.0');
  assert.throws(() => click(p, 'go'), e => /square root/.test(e.msg));
});
test('Int division still floors; Float division is exact', () => {
  assert.strictEqual(txt1('text toText(7 / 2) + " " + toText(7.0 / 2.0)'), '3 3.5');
});
test('tip calculator example', () => {
  const p = T.load(ex('tip'));
  type(p, 'bill', '80'); click(p, '20%');
  const t = text(p);
  assert(t.includes('Tip (20%): $16.00') && t.includes('Total: $96.00'), t);
  type(p, 'bill', 'abc');
  assert(text(p).includes('Total: $0.00'));
});

// ---- Font
test('Font type and constants', () => {
  const p = page('text "a" font serif\ntext "b" font f', 'state f: Font = mono');
  const r = p.render();
  assert.strictEqual(r[0].style.font, 'serif'); assert.strictEqual(r[1].style.font, 'mono');
  expectErr('view { text "a" font "serif" }', 'type error', 'needs Font');
  expectErr('view { text "a" font 3 }', 'type error', 'needs Font');
});

// ---- richer styling: buttons, boxes
test('buttons can be styled in depth', () => {
  const p = page('button "Go" size 18 bold font rounded color white background blue padding 14 radius 999 border #003 width 220 -> n = 1', 'state n: Int = 0');
  assert.deepStrictEqual(p.render()[0].style, { size: 18, bold: true, font: 'rounded', color: '#ffffff', background: '#0b57d0', padding: 14, radius: 999, border: '#000033', width: 220 });
});
test('button style via named style', () => {
  const p = page('button "Go" style cta -> n = 1', 'state n: Int = 0\nstyle cta { background blue color white radius 10 align center }');
  assert.deepStrictEqual(p.render()[0].style, { background: '#0b57d0', color: '#ffffff', radius: 10 });
});
test('box props on rows/columns, clamped', () => {
  const r = page('column background gray padding 12 radius 5000 border red width 9999 { text "x" }').render()[0];
  assert.deepStrictEqual(r.style, { background: '#6e7781', padding: 12, radius: 999, border: '#d1242f', width: 2000 });
});
test('text can have padding/radius/border', () => {
  assert.deepStrictEqual(page('text "x" padding 8 radius 6 border gray').render()[0].style, { padding: 8, radius: 6, border: '#6e7781' });
});
test('props that do not belong are still rejected', () => {
  expectErr('view { button "b" align center -> n = 1 }\nstate n: Int = 0', 'type error', "a button cannot have 'align'");
  expectErr('view { text "b" width 100 }', 'type error', "a text cannot have 'width'");
  expectErr('view { link "b" to "x" padding 3 }', 'type error', "a link cannot have 'padding'");
});

// ---- navigation
const SITE = `state hits: Int = 0
view home {
  text "HOME"
  button "Go menu" -> goto menu
  button "Hit" -> hits = hits + 1
}
view menu {
  text "MENU " + toText(hits)
  button "Go about" -> { hits = hits + 10 goto about }
  button "Back" -> back
}
view about {
  text "ABOUT"
  link "Home" -> goto home
  button "Back" -> back
}`;
test('several pages: start on the first, goto and back', () => {
  const p = T.load('page "s"\n' + SITE);
  assert.deepStrictEqual(p.screens, ['home', 'menu', 'about']);
  assert.strictEqual(p.screen, 'home'); assert(text(p).includes('HOME'));
  click(p, 'Hit', 2); click(p, 'Go menu');
  assert.strictEqual(p.screen, 'menu'); assert(text(p).includes('MENU 2'));
  click(p, 'Go about');
  assert.strictEqual(p.screen, 'about'); assert.deepStrictEqual(p.history, ['home', 'menu']);
  click(p, 'Back'); assert.strictEqual(p.screen, 'menu'); assert(text(p).includes('MENU 12'));
  click(p, 'Back'); assert.strictEqual(p.screen, 'home');
  p.back(); assert.strictEqual(p.screen, 'home'); // nothing to go back to
});
test('a link can run an action', () => {
  const p = T.load('page "s"\n' + SITE);
  click(p, 'Go menu'); click(p, 'Go about');
  const l = p.render().find(n => n.t === 'link'); assert.strictEqual(l.target, null);
  l.click(); assert.strictEqual(p.screen, 'home');
});
test('goto from a function, and to the current page does nothing', () => {
  const p = T.load('fn leave() { goto b }\nview a { button "x" -> leave() }\nview b { text "B" button "y" -> goto b }');
  click(p, 'x'); assert.strictEqual(p.screen, 'b'); assert.strictEqual(p.history.length, 1);
  click(p, 'y'); assert.strictEqual(p.history.length, 1);
});
test('navigation errors', () => {
  expectErr('view { button "x" -> goto nowhere }', 'type error', "no page called 'nowhere'");
  expectErr('view { text "a" }\nview { text "b" }', 'type error', "two pages called 'home'");
  expectErr('view a { text "a" }\nview a { text "b" }', 'type error', "two pages called 'a'");
  expectErr('view a { button "x" -> goto }', 'syntax error', 'name of a page');
});
test('a single unnamed view is called home', () => {
  const p = T.load('view { text "x" button "h" -> goto home }');
  assert.deepStrictEqual(p.screens, ['home']);
});
test('multi-page example runs', () => {
  const p = T.load(ex('pages'));
  assert(p.screens.length === 3);
  click(p, 'Menu'); assert(text(p).includes('Espresso') && text(p).includes('$2.50'));
  click(p, 'Back'); click(p, 'About'); assert.strictEqual(p.screen, 'about');
});

// ---- images
test('image node with size, alt and style', () => {
  const n = page('image "mountains" width 200 height 100 radius 12 alt "Peaks" align center border gray', '').render()[0];
  assert.deepStrictEqual(n, { t: 'image', src: 'mountains', alt: 'Peaks', style: { width: 200, height: 100, radius: 12, align: 'center', border: '#6e7781' } });
});
test('image source can be computed', () => {
  assert.strictEqual(page('image pic', 'state pic: Text = "logo"').render()[0].src, 'logo');
});
test('image names are checked when the host knows its assets', () => {
  const ok = T.load('view { image "logo" }', { assets: ['logo', 'sunset'] });
  assert.strictEqual(ok.render()[0].src, 'logo');
  assert.throws(() => T.load('view { image "lgo" }', { assets: ['logo', 'sunset'] }),
    e => e.phase === 'type error' && e.msg.includes('no image called "lgo"') && e.msg.includes('logo, sunset'));
  T.load('view { image "https://example.com/a.png" }', { assets: [] });   // web address is fine
  T.load('view { image "data:image/png;base64,AAAA" }', { assets: [] });
  T.load('view { image "anything" }');   // no assets given: not checked
});
test('image errors', () => {
  expectErr('view { image 5 }', 'type error', 'needs Text');
  expectErr('view { image "a" color red }', 'type error', "an image cannot have 'color'");
  expectErr('view { image "a" width "wide" }', 'type error', 'needs Int');
});
test('all new examples load', () => {
  for (const id of ['pages', 'tip', 'fonts', 'images', 'buttons', 'structs']) T.load(ex(id), { assets: ['mountains', 'sunset', 'avatar', 'logo'] }).render();
});

// ---- structs (0.4)
const ITEM = 'struct Item {\n  name: Text\n  price: Int\n  qty: Int\n}\n';
test('struct: create, read, with, list', () => {
  const p = page(
    'for i in cart { text i.name + " " + toText(lineTotal(i)) }\nbutton "more" -> bump(0)',
    ITEM + 'state cart: List<Item> = [Item(name: "Tea", price: 3, qty: 2)]\n' +
    'fn lineTotal(i: Item): Int { return i.price * i.qty }\n' +
    'fn bump(n: Int) { cart = setAt(cart, n, cart[n] with qty: cart[n].qty + 1) }');
  assert.strictEqual(text(p).split('\n')[0], 'Tea 6');
  click(p, 'more');
  assert.strictEqual(text(p).split('\n')[0], 'Tea 9');
});
test('struct: with leaves the original alone, equality is by value', () => {
  const p = page('text toText(a == b) + toText(a == c) + toText(a.qty)',
    ITEM + 'state a: Item = Item(name: "T", price: 1, qty: 1)\nstate b: Item = Item(qty: 1, price: 1, name: "T")\nstate c: Item = a with qty: 2, price: 5');
  assert.strictEqual(text(p), 'truefalse1');
});
test('struct: nested', () => {
  const p = page('text o.item.name', ITEM + 'struct Order {\n item: Item\n note: Text\n}\nstate o: Order = Order(item: Item(name: "X", price: 1, qty: 1), note: "n")');
  assert.strictEqual(text(p), 'X');
});
test('struct errors', () => {
  const bad = (body, msg) => { const e = errOf(`page "t"\n${ITEM}state s: Item = Item(name: "a", price: 1, qty: 1)\nview {\n${body}\n}`); assert.ok(e.msg.includes(msg), e.msg); return e; };
  bad('text s.nope', "no field 'nope'");
  bad('text s.price', 'needs Text');
  bad('text s', 'needs Text');
  bad('text toText(s)', 'toText() works on');
  bad('text toText(5.name)', 'only a struct has fields');
  const m = errOf(`page "t"\n${ITEM}view { text Item(name: "a").name }`); assert.ok(m.msg.includes('needs price: Int, qty: Int'), m.msg);
  assert.ok(errOf(`page "t"\n${ITEM}view { text Item("a", 1, 2).name }`).msg.includes('named fields'));
  assert.ok(errOf(`page "t"\n${ITEM}view { text Item(name: "a", price: "x", qty: 1).name }`).msg.includes('needs Int'));
  assert.ok(errOf(`page "t"\n${ITEM}view { text Item(name: "a", name: "b", price: 1, qty: 1).name }`).msg.includes('twice'));
  assert.ok(errOf(`page "t"\n${ITEM}state s: Item = Item(name: "a", price: 1, qty: 1)\nview { text (s with qty: "z").name }`).msg.includes('needs Int'));
  assert.ok(errOf(`page "t"\n${ITEM}view { text Item.name }`).msg.includes('is a struct'));
});
test('struct declaration errors', () => {
  assert.ok(errOf('struct A {\n b: A\n}\nview { text "x" }').msg.includes('contains itself'));
  assert.ok(errOf('struct A {\n b: List<B>\n}\nstruct B {\n a: A\n}\nview { text "x" }').msg.includes('contains itself'));
  assert.ok(errOf('struct Int {\n b: Int\n}\nview { text "x" }').msg.includes('built-in'));
  assert.ok(errOf('struct A {\n b: Int\n}\nstruct A {\n b: Int\n}\nview { text "x" }').msg.includes('twice'));
  assert.ok(errOf('struct A {\n}\nview { text "x" }').msg.includes('at least one'));
  assert.ok(errOf('struct A {\n size: Int\n}\nview { text "x" }').msg.includes('reserved'));
  assert.ok(errOf('struct A {\n b: Nope\n}\nview { text "x" }').msg.includes('unknown type'));
});

// ---- methods and field assignment on structs
const STOCK = 'struct Item {\n  name: Text\n  quantity: Int\n' +
  '  fn take(qty: Int) {\n    if self.quantity - qty > 0 {\n      self.quantity = self.quantity - qty\n    }\n  }\n' +
  '  fn restock() {\n    self.quantity = self.quantity + 10\n    self.take(0)\n  }\n' +
  '  fn label(): Text { return self.name + " x" + toText(self.quantity) }\n}\n';
test('methods: change self through a state list, label returns a value', () => {
  const p = page('text stock[0].label()\nbutton "take" -> stock[0].take(2)\nbutton "restock" -> stock[1].restock()',
    STOCK + 'state stock: List<Item> = [Item(name: "Tea", quantity: 5), Item(name: "Cake", quantity: 1)]');
  const first = () => text(p).split('\n')[0];
  assert.strictEqual(first(), 'Tea x5');
  click(p, 'take'); assert.strictEqual(first(), 'Tea x3');
  click(p, 'take'); assert.strictEqual(first(), 'Tea x1');
  click(p, 'take'); assert.strictEqual(first(), 'Tea x1');          // 1 - 2 is not > 0, so nothing changes
  click(p, 'restock'); assert.ok(text(p).includes('Tea x1'));
});
test('methods and fields: values are copies', () => {
  const p = page('text toText(a.quantity) + " " + toText(b.quantity)',
    STOCK + 'state a: Item = Item(name: "A", quantity: 5)\nstate b: Item = a\nfn go() { b.take(2) }');
  assert.strictEqual(text(p), '5 5');
  const q = page('text toText(a.quantity) + " " + toText(b.quantity)\nbutton "go" -> go()',
    STOCK + 'state a: Item = Item(name: "A", quantity: 5)\nstate b: Item = a\nfn go() { b.take(2) }');
  click(q, 'go'); assert.strictEqual(text(q).split('\n')[0], '5 3');
});
test('field assignment: nested paths, locals, lists', () => {
  const p = page('text toText(o.item.quantity) + " " + toText(o.item.name) + " " + toText(xs[1].quantity)\nbutton "go" -> go()',
    STOCK.replace(/  fn[\s\S]*$/, '}\n') + 'struct Order {\n  item: Item\n}\nstate o: Order = Order(item: Item(name: "T", quantity: 1))\n' +
    'state xs: List<Item> = [Item(name: "a", quantity: 1), Item(name: "b", quantity: 2)]\n' +
    'fn go() {\n  o.item.quantity = 9\n  xs[1].quantity = xs[1].quantity * 10\n  let local = xs[0]\n  local.quantity = 77\n}');
  click(p, 'go'); assert.strictEqual(text(p).split('\n')[0], '9 T 20');
});
test('method inside a method sees the changed self; nested struct methods', () => {
  const p = page('text toText(g.n) + " " + toText(g.inner.n)\nbutton "go" -> g.bump()',
    'struct In {\n  n: Int\n  fn inc() { self.n = self.n + 1 }\n}\nstruct Out {\n  n: Int\n  inner: In\n  fn bump() {\n    self.n = self.n + 1\n    self.inner.inc()\n    self.inner.inc()\n  }\n}\nstate g: Out = Out(n: 0, inner: In(n: 0))');
  click(p, 'go', 2); assert.strictEqual(text(p).split('\n')[0], '2 4');
});
test('method errors and field-assignment errors', () => {
  const e = (src, needle) => { const x = errOf(src); assert.ok(x.msg.includes(needle), x.msg); };
  const base = 'page "t"\n' + STOCK + 'state s: Item = Item(name: "a", quantity: 1)\nstate xs: List<Item> = [s]\n';
  e(base + 'view { text Item(name: "a", quantity: 1).take(1) }', 'own statement');
  e(base + 'fn f() { Item(name: "a", quantity: 1).take(1) }\nview { text "x" }', 'only a variable');
  e(base + 'fn f() { let x = s.take(1) }\nview { text "x" }', 'own statement');
  e(base + 'view { for i in xs { button "x" -> i.take(1) } }', 'copy of a list item');
  e(base + 'fn f() { xs[0] = s }\nview { text "x" }', 'setAt');
  e(base + 'fn f() { s.nope = 1 }\nview { text "x" }', "no field 'nope'");
  e(base + 'fn f() { s.quantity = "x" }\nview { text "x" }', 'needs Int');
  e(base + 'fn f() { s.nope(1) }\nview { text "x" }', "no method 'nope'");
  e(base + 'fn f() { s.take() }\nview { text "x" }', 'takes 1 argument');
  e(base + 'fn f() { s.take("x") }\nview { text "x" }', 'needs Int');
  e(base + 'fn f() { s.quantity() }\nview { text "x" }', 'is a field');
  e(base + 'fn f() { 5.take(1) }\nview { text "x" }', 'only a struct has methods');
  e(base + 'view { text toText(self.quantity) }', "only exists inside");
  e(base + 'fn f() { 5 = 6 }\nview { text "x" }', 'change a variable or a field');
  e('struct A {\n n: Int\n fn n() { }\n}\nview { text "x" }', 'defined twice');
  e('struct A {\n n: Int\n fn get(): Int { self.n = 1\n return self.n }\n}\nview { text "x" }', 'cannot change self');
  e('struct A {\n n: Int\n fn inc() { self.n = 1 }\n fn get(): Int { self.inc()\n return self.n }\n}\nview { text "x" }', 'cannot change self');
  e('struct A {\n n: Int\n fn get(): Int { }\n}\nview { text "x" }', 'must return');
});
test('field assignment: runtime index error is reported, page keeps working', () => {
  const p = page('button "go" -> xs[5].quantity = 1\ntext "ok"', STOCK + 'state xs: List<Item> = [Item(name: "a", quantity: 1)]');
  assert.throws(() => click(p, 'go'), x => x instanceof T.TernError && x.phase === 'runtime error' && x.msg.includes('outside the list'));
});
test('method on an out-of-range list item is a runtime error', () => {
  const p = page('button "go" -> xs[5].take(1)\ntext "ok"', STOCK + 'state xs: List<Item> = [Item(name: "a", quantity: 3)]');
  assert.throws(() => click(p, 'go'), x => x instanceof T.TernError && x.phase === 'runtime error' && x.msg.includes('outside the list'));
});
test('library structs can have methods', () => {
  const lib = 'struct Box {\n  n: Int\n  fn bump(by: Int) { self.n = self.n + by }\n  fn show(): Text { return "n=" + toText(self.n) }\n}\nfn make(): Box { return Box(n: 1) }\n';
  const p = T.load('use "bx.ternlib"\nstate b: bx.Box = bx.make()\nview {\n  text b.show()\n  button "g" -> b.bump(4)\n}', { libraries: { bx: lib } });
  assert.strictEqual(text(p).split('\n')[0], 'n=1'); click(p, 'g'); assert.strictEqual(text(p).split('\n')[0], 'n=5');
});

// ---- libraries (use "x.ternlib")
const SHOP = 'struct Item {\n  name: Text\n  price: Int\n  qty: Int\n}\n' +
  'fn make(n: Text, p: Int): Item { return Item(name: n, price: p, qty: 1) }\n' +
  'fn lineTotal(i: Item): Int { return i.price * i.qty }\n' +
  'fn sum(items: List<Item>): Int {\n  let t = 0\n  for i in items { t = t + lineTotal(i) }\n  return t\n}\n';
const withLib = (body, decls = '', libs = { shop: SHOP }) => T.load(`page "t"\nuse "shop.ternlib"\n${decls}\nview {\n${body}\n}`, { libraries: libs });
test('library: functions and structs under a prefix', () => {
  const p = withLib('text toText(shop.sum(cart))\nbutton "add" -> cart = append(cart, shop.make("Cake", 5))',
    'state cart: List<shop.Item> = [shop.Item(name: "Tea", price: 3, qty: 2)]');
  assert.strictEqual(text(p).split('\n')[0], '6');
  click(p, 'add');
  assert.strictEqual(text(p).split('\n')[0], '11');
});
test('library: page names do not clash with library names', () => {
  const p = withLib('text toText(sum(1, 2) + shop.lineTotal(shop.make("a", 4)))', 'fn sum(a: Int, b: Int): Int { return a + b }');
  assert.strictEqual(text(p), '7');
});
test('library errors name the file', () => {
  const bad = (libSrc, needle) => {
    let e; try { withLib('text "x"', '', { shop: libSrc }); } catch (x) { e = x; }
    assert.ok(e && e.file === 'shop.ternlib' && e.msg.includes(needle), e && e.toString());
    assert.ok(e.toString().includes('in shop.ternlib'));
  };
  bad('fn f(): Int { return "a" }', 'needs Int');
  bad('state n: Int = 1', 'keep');
  bad('view { text "x" }', 'keep');
  bad('use "other.ternlib"', 'other libraries');
  bad('fn f(): Int { return count }', 'unknown name');
  bad('fn len(x: Int): Int { return x }', 'built-in');
  bad('fn f() { goto home }', 'no page');
});
test('library use errors', () => {
  const e1 = (src, libs, needle) => { try { T.load(src, { libraries: libs }); } catch (e) { assert.ok(e.msg.includes(needle), e.msg); return; } throw new Error('expected error'); };
  e1('use "shop.ternlib"\nview { text "x" }', {}, 'was not found');
  e1('use "dir/shop.ternlib"\nview { text "x" }', {}, 'no folders');
  e1('use "shop.ternlib"\nuse "shop.ternlib"\nview { text "x" }', { shop: SHOP }, 'twice');
  e1('use "text.ternlib"\nview { text "x" }', { text: SHOP }, 'cannot be a library name');
  e1('use "shop.ternlib"\nview { text toText(shop.nope(1)) }', { shop: SHOP }, "has no 'nope'");
  e1('use "shop.ternlib"\nstate shop: Int = 1\nview { text "x" }', { shop: SHOP }, 'name of a library');
  e1('use "shop.ternlib"\nview { text shop.lineTotal }', { shop: SHOP }, 'is a function');
  e1('use "shop.ternlib"\nview { text toText(shop.lineTotal(5)) }', { shop: SHOP }, 'needs shop.Item');
  e1('use "shop.ternlib"\nview { text toText(Item(1)) }', { shop: SHOP }, 'unknown function');
});

test('library example runs', () => {
  const e = EXAMPLES.find(x => x.id === 'library');
  const p = T.load(e.src, { libraries: e.libs });
  assert.ok(text(p).includes('Total: $8'));
  click(p, 'Add tea');
  assert.ok(text(p).includes('Total: $11'));
});
test('old reserved names are only the documented ones', () => {
  // a page using ordinary names still works
  const p = page('text name + " " + toText(count)', 'state name: Text = "n"\nstate count: Int = 3');
  assert.strictEqual(p.render()[0].text, 'n 3');
});



// ================= struct defaults & components =================
test('struct defaults: omit defaulted fields, require others', () => {
  const p = page('text p.name + " " + toText(p.qty)', 'struct Item { name: Text\n qty: Int = 1\n note: Text = "" }\nstate p: Item = Item(name: "Tea")');
  assert.strictEqual(text(p), 'Tea 1');
});
test('struct defaults: override and all-default construct', () => {
  const p = page('text a.note + toText(b.qty)', 'struct Item { name: Text = "x"\n qty: Int = 1\n note: Text = "n" }\nstate a: Item = Item(note: "hi")\nstate b: Item = Item(qty: 3)');
  assert.strictEqual(text(p), 'hi3');
});
test('struct defaults: missing required field is an error', () => {
  const e = errOf('page "t"\nstruct Item { name: Text\n qty: Int = 1 }\nstate p: Item = Item(qty: 2)\nview { text "" }');
  assert.ok(e.phase === 'type error' && e.msg.includes('name'), e.msg);
});
test('struct defaults: default type checked', () => {
  const e = errOf('page "t"\nstruct Item { name: Text = 1 }\nstate p: Item = Item(name: "a")\nview { text "" }');
  assert.strictEqual(e.phase, 'type error');
});

test('component: inline declaration and render', () => {
  const p = T.load('page "t"\nstruct P { title: Text }\ncomponent Card(p: P) { heading p.title\n text "body" }\nview { Card(title: "Hi") }');
  assert.deepStrictEqual(T.renderText(p.render()), ['HI', 'body']);
});
test('component: prop defaults and expressions', () => {
  const p = T.load('page "t"\nstruct P { name: Text\n n: Int = 2\n label: Text = "x" }\ncomponent C(p: P) { text p.name + " " + toText(p.n) + p.label }\nview { C(name: "A")\n C(name: "B", n: 5, label: "!") }');
  assert.deepStrictEqual(T.renderText(p.render()), ['A 2x', 'B 5!']);
});
test('component: reuses on a page and in a loop', () => {
  const p = T.load('page "t"\nstruct P { t: Text }\ncomponent Tag(p: P) { bullet p.t }\nstate xs: List<Text> = ["a", "b"]\nview { Tag(t: "z")\n for x in xs { Tag(t: x) } }');
  assert.deepStrictEqual(T.renderText(p.render()), ['* z', '* a', '* b']);
});
test('component errors: unknown, missing, duplicate, type, unknown prop', () => {
  const bad = (src, msg) => { const e = errOf(src); assert.ok(e.phase === 'type error' && e.msg.includes(msg), e.msg); };
  const base = 'page "t"\nstruct P { title: Text\n n: Int = 1 }\ncomponent Card(p: P) { text p.title }\n';
  bad(base + 'view { Card() }', 'needs');
  bad(base + 'view { Card(nope: "x") }', 'no property');
  bad(base + 'view { Card(title: "x", title: "y") }', 'twice');
  bad(base + 'view { Card(title: 5) }', 'needs Text');
  bad(base + 'view { Missing(title: "x") }', 'unknown component');
});
test('component: import from component source map', () => {
  const card = 'struct CardP { title: Text\n sub: Text = "" }\ncomponent Card(p: CardP) { heading p.title\n if p.sub != "" { text p.sub } }';
  const p = T.load('page "t"\nimport component Card from "Card.tern"\nview { Card(title: "Hi", sub: "yo") }', { components: { 'Card.tern': card } });
  assert.deepStrictEqual(T.renderText(p.render()), ['HI', 'yo']);
});
test('component: import shorthand and default props', () => {
  const card = 'struct CardP { title: Text\n sub: Text = "" }\ncomponent Card(p: CardP) { heading p.title }';
  const p = T.load('page "t"\nimport component Card\nview { Card(title: "Hi") }', { components: { 'Card.tern': card } });
  assert.deepStrictEqual(T.renderText(p.render()), ['HI']);
});
test('component: can use a .ternlib for helpers', () => {
  const card = 'use "fmt.ternlib"\nstruct P { name: Text }\ncomponent Hello(p: P) { text fmt.greet(p.name) }';
  const lib = 'fn greet(who: Text): Text { return "hi " + who }';
  const p = T.load('page "t"\nimport component Hello\nview { Hello(name: "Jo") }', { components: { 'Hello.tern': card }, libraries: { fmt: lib } });
  assert.deepStrictEqual(T.renderText(p.render()), ['hi Jo']);
});
test('component import errors', () => {
  const err2 = (src, opts) => { try { T.load(src, opts); } catch (e) { return e; } throw new Error('expected an error'); };
  const e1 = err2('page "t"\nimport component Card\nview { text "x" }');
  assert.ok(e1.phase === 'import error' && e1.msg.includes('not found'), e1.msg);
  const e2 = err2('page "t"\nimport component Card\nview { text "x" }', { components: { 'Card.tern': 'struct P { x: Int }\ncomponent Other(p: P) { text "x" }' } });
  assert.ok(e2.phase === 'import error' && e2.msg.includes('does not define'), e2.msg);
});


// ================= Action callbacks =================
test('action callback prop: close a card', () => {
  const p = T.load(`page "t"
struct CardP { title: Text, onClose: Action }
component Card(p: CardP) {
  row { text p.title
  button "X" -> p.onClose() }
}
state show: Bool = true
view {
  if show { Card(title: "Hi", onClose: action { show = false }) }
  if !show { text "closed" }
}`);
  assert.ok(T.renderText(p.render()).join('\n').includes('[ X ]'));
  findBtn(p.render(), 'X').click();
  assert.deepStrictEqual(T.renderText(p.render()), ['closed']);
});
test('action callback: can mutate caller state and locals captured at call site', () => {
  const p = T.load(`page "t"
struct P { run: Action }
component C(p: P) { button "go" -> p.run() }
state n: Int = 0
view {
  C(run: action { n = n + 2 })
  text toText(n)
}`);
  findBtn(p.render(), 'go').click();
  assert.deepStrictEqual(T.renderText(p.render()), ['[ go ]', '2']);
});
test('action callback: multiple cards with different actions', () => {
  const p = T.load(`page "t"
struct P { label: Text, onPick: Action }
component Btn(p: P) { button p.label -> p.onPick() }
state which: Text = ""
view {
  Btn(label: "A", onPick: action { which = "a" })
  Btn(label: "B", onPick: action { which = "b" })
  text which
}`);
  findBtn(p.render(), 'B').click();
  assert.deepStrictEqual(T.renderText(p.render()), ['[ A ]', '[ B ]', 'b']);
});
test('action errors', () => {
  const err2 = (src, msg) => { const e = errOf(src); assert.ok(e.phase === 'type error' && e.msg.includes(msg), e.msg); };
  err2(`page "t"
struct P { onClose: Action }
component C(p: P) { text "x" }
view { C(onClose: 1) }`, 'needs Action');
  err2(`page "t"
struct P { onClose: Action }
state a: Action = action { }
state b: Action = action { }
view { if a == b { text "x" } }`, 'cannot compare Action');
  err2(`page "t"
struct P { onClose: Action }
component C(p: P) { button "x" -> p.onClose(1) }
view { text "x" }`, 'takes no arguments');
});

console.log(`${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
