"""Builds Learn_Tern.pdf. Every code sample is executed through Tern first;
screenshots and error messages in the PDF are real output."""
import os
import re
import json
import subprocess
import sys

from PIL import Image as PILImage
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import (BaseDocTemplate, CondPageBreak, Frame, Image, KeepTogether, PageBreak,
                                PageTemplate, Paragraph, Preformatted, Spacer, Table, TableStyle)
from reportlab.platypus.tableofcontents import TableOfContents


OUT = os.path.dirname(os.path.abspath(__file__))   # the guide folder; Learn_Tern.pdf and img/ go here
IMG = os.path.join(OUT, "img")
os.makedirs(IMG, exist_ok=True)

# ---------------------------------------------------------------- samples
S = {}
LIBS_BY_SRC = {}   # page source -> {library name: library source}, for pages that use `use`

S["hello"] = '''page "Hello"

view {
  heading "Hello, Tern!"
  text "This is my first page."
}
'''

S["types"] = '''page "Types"

state name: Text = "Sam"
state age: Int = 30
state happy: Bool = true
state scores: List<Int> = [90, 85, 70]

view {
  text name + " is " + toText(age)
  text "Happy? " + toText(happy)
  text "Number of scores: " + toText(len(scores))
}
'''

S["counter"] = '''page "Counter"

state count: Int = 0

view {
  heading "Counter"
  text "Count: " + toText(count)
  row {
    button "-" -> count = count - 1
    button "+" -> count = count + 1
    button "Reset" -> count = 0
  }
}
'''

S["functions"] = '''page "Functions"

fn double(n: Int): Int {
  return n * 2
}

fn shout(s: Text): Text {
  return upper(s) + "!"
}

view {
  text "Double 21 is " + toText(double(21))
  text shout("tern")
}
'''

S["grades"] = '''page "Grades"

state score: Int = 72

fn grade(s: Int): Text {
  if s >= 90 {
    return "A"
  } else if s >= 70 {
    return "B"
  } else {
    return "C"
  }
}

fn sum(xs: List<Int>): Int {
  let total = 0
  for x in xs {
    total = total + x
  }
  return total
}

view {
  text "Score " + toText(score) + " is grade " + grade(score)
  text "1 + 2 + 3 + 4 = " + toText(sum([1, 2, 3, 4]))
  for n in range(3) {
    text "Row " + toText(n)
  }
}
'''

S["foreach_demo"] = '''page "Foreach"

state fruits: List<Text> = ["Apple", "Banana", "Cherry"]

view {
  heading "Fruit"
  foreach fruit in fruits {
    text fruit
  }
}
'''

S["profile"] = '''page "Profile"

state name: Text = ""
state subscribed: Bool = false

fn status(): Text {
  if subscribed {
    return "You are subscribed."
  }
  return "You are not subscribed."
}

view {
  heading "Profile"
  input name placeholder "Your name"
  if trim(name) != "" {
    text "Hello, " + trim(name) + "!"
  }
  divider
  text status()
  row {
    button "Subscribe" -> subscribed = true
    button "Unsubscribe" -> subscribed = false
  }
  divider
  link "Back to the start" to "hello.tern"
}
'''

S["shopping"] = '''page "Shopping list"

state items: List<Text> = ["Milk", "Eggs"]
state draft: Text = ""

fn add() {
  if trim(draft) != "" {
    items = append(items, trim(draft))
    draft = ""
  }
}

view {
  heading "Shopping list"
  row {
    input draft placeholder "Add an item"
    button "Add" -> add()
  }
  if len(items) == 0 {
    text "Nothing to buy."
  }
  for i in range(len(items)) {
    row {
      text toText(i + 1) + ". " + items[i]
      button "Remove" -> items = removeAt(items, i)
    }
  }
}
'''

S["quiz"] = '''page "Quiz"

state questions: List<Text> = ["What is 2 + 2?", "Capital of France?", "Is 7 prime?"]
state answers: List<Text> = ["4", "Paris", "yes"]
state index: Int = 0
state score: Int = 0
state guess: Text = ""
state feedback: Text = ""

fn submit() {
  if lower(trim(guess)) == lower(answers[index]) {
    score = score + 1
    feedback = "Correct!"
  } else {
    feedback = "Not quite. The answer was " + answers[index] + "."
  }
  guess = ""
  index = index + 1
}

fn restart() {
  index = 0
  score = 0
  feedback = ""
}

view {
  heading "Quiz"
  if index < len(questions) {
    text "Question " + toText(index + 1) + ": " + questions[index]
    input guess placeholder "Your answer"
    button "Submit" -> submit()
  } else {
    text "Finished! Score: " + toText(score) + " out of " + toText(len(questions))
    button "Play again" -> restart()
  }
  text feedback
}
'''

# exercise solutions
S["ex1"] = '''page "Full name"

state first: Text = ""
state last: Text = ""

view {
  input first placeholder "First name"
  input last placeholder "Last name"
  text "Full name: " + trim(first + " " + last)
}
'''

S["ex2"] = '''page "Counter with a floor"

state count: Int = 0

fn down() {
  if count > 0 {
    count = count - 1
  }
}

view {
  text "Count: " + toText(count)
  row {
    button "-" -> down()
    button "+" -> count = count + 1
  }
}
'''

S["ex3"] = '''page "Todo with clear"

state items: List<Text> = ["One", "Two", "Three"]

view {
  for item in items {
    text item
  }
  button "Clear all" -> items = []
}
'''

S["ex4"] = '''page "FizzBuzz"

fn fizz(n: Int): Text {
  if n % 15 == 0 { return "FizzBuzz" }
  if n % 3 == 0 { return "Fizz" }
  if n % 5 == 0 { return "Buzz" }
  return toText(n)
}

view {
  for i in range(15) {
    text fizz(i + 1)
  }
}
'''


S["style_text"] = """page "Text styles"

view {
  heading "Text styles"
  text "Normal text"
  text "Bigger" size 20
  text "Bold" bold
  text "Italic" italic
  text "Underlined" underline
  text "Struck through" strike
  text "Red and bold" color red bold
  text "Highlighted" background #fff3bf
  text "Centered" align center
  text "Everything at once" size 18 bold italic underline color purple
}
"""

S["colors"] = """page "Colours"

state tint: Color = orange

fn shade(level: Int): Color {
  return rgb(level, 80, 255 - level)
}

view {
  text "By name" color green
  text "By hex" color #0b57d0
  text "By rgb" color rgb(200, 40, 120)
  text "From a state" color tint
  text "From a function" color shade(120)
  row {
    button "Orange" -> tint = orange
    button "Purple" -> tint = purple
  }
}
"""

S["dyn"] = """page "Done or not"

state done: Bool = false
state pts: Int = 14

view {
  text "Write the report" strike when done bold when !done size pts
  row {
    button "Toggle done" -> done = !done
    button "Bigger" -> pts = pts + 2
  }
}
"""

S["para"] = """page "Mixed text"

view {
  para {
    span "Tern is "
    span "small" bold
    span ", "
    span "typed" italic color blue
    span " and "
    span "friendly" underline
    span "."
  }
  para size 14 color gray {
    span "Everything here is size 14 and gray, "
    span "except this bit." color red
  }
  heading "Shopping" size 16
  bullet "Milk"
  bullet "Eggs"
  bullet "Bread" bold
}
"""

S["tables"] = """page "Scores"

state names: List<Text> = ["Ada", "Grace", "Linus"]
state points: List<Int> = [92, 88, 75]

view {
  heading "Scoreboard"
  table {
    header "Player", "Points"
    for i in range(len(names)) {
      cells names[i], toText(points[i])
    }
  }
}
"""

S["styles"] = """page "Named styles"

style title { size 26 bold color blue }
style note { italic color gray size 11 }
style warning { bold color red background #fdecea }
style card { background #eef3fc padding 12 }

view {
  text "Named styles" style title
  text "Defined once at the top." style note
  column style card {
    text "A card" bold
    text "Backgrounds and padding work on rows and columns." style note
  }
  text "Heads up!" style warning
  text "A bigger heads up!" style warning size 20
}
"""

S["ex5"] = """page "Profile card"

style card { background #eef3fc padding 14 }

view {
  column style card {
    heading "Ada Lovelace" size 20
    text "Mathematician" italic color gray
    para {
      span "Wrote the "
      span "first program" bold
      span " in 1843."
    }
  }
}
"""

S["ex6"] = """page "Expenses"

state labels: List<Text> = ["Rent", "Food", "Travel"]
state costs: List<Int> = [900, 300, 120]

fn total(): Int {
  let sum = 0
  for c in costs {
    sum = sum + c
  }
  return sum
}

view {
  table {
    header "Item", "Cost"
    for i in range(len(labels)) {
      cells labels[i], "$" + toText(costs[i])
    }
    cells "Total", "$" + toText(total())
  }
}
"""

# examples that live in the playground are reused so the guide never drifts from it
_ex = json.loads(subprocess.run(["node", "-e", "console.log(JSON.stringify(require(process.argv[1]).EXAMPLES))",
                                 os.path.join(os.path.dirname(OUT), "playground", "examples.js")],
                                capture_output=True, text=True, check=True).stdout)
EX = {e["id"]: e["src"] for e in _ex}
S["cafe"], S["buttons"], S["fonts"], S["images"], S["tipcalc"] = EX["pages"], EX["buttons"], EX["fonts"], EX["images"], EX["tip"]

S["nav_basic"] = """page "Two pages"

state visits: Int = 0

view home {
  heading "Home"
  text "You have opened the shop " + toText(visits) + " time(s)."
  button "Open the shop" -> {
    visits = visits + 1
    goto shop
  }
}

view shop {
  heading "Shop"
  text "Nothing for sale yet."
  button "Back" -> back
}
"""

S["box"] = """page "Card"

view {
  column border gray radius 8 padding 12 width 260 {
    text "Card title" bold
    text "Anything can go inside a box."
    button "OK" -> goto home
  }
}
"""

S["float"] = """page "Decimals"

state price: Float = 2.5
state qty: Int = 3

fn total(): Float {
  return price * toFloat(qty)
}

view {
  text "Price: " + toText(price)
  text "Total: $" + fixed(total(), 2) bold
  text "Rounded: " + toText(round(total()))
  text "Half: " + toText(total() / 2.0)
  button "Raise price" -> price = price + 0.25
}
"""

S["ex7"] = """page "My site"

style btn { background blue color white radius 8 padding 10 }

view home {
  heading "Welcome"
  button "Contact me" style btn -> goto contact
}

view contact {
  heading "Contact"
  text "hello@example.com"
  button "Back" style btn -> back
}
"""

S["ex8"] = """page "Split the bill"

state bill: Text = ""
state people: Int = 2

fn fewer() {
  if people > 1 {
    people = people - 1
  }
}

fn each(): Float {
  return toFloatOr(bill, 0.0) / toFloat(people)
}

view {
  input bill placeholder "Bill"
  row {
    button "-" -> fewer()
    text toText(people) + " people"
    button "+" -> people = people + 1
  }
  text "Each pays $" + fixed(each(), 2) bold
}
"""


S["struct_basic"] = """page "Profile"

struct Person {
  name: Text
  age: Int

  fn greeting(): Text {
    return "Hello, " + self.name
  }

  fn birthday() {
    self.age = self.age + 1
  }
}

state me: Person = Person(name: "Ada", age: 36)

view {
  heading me.greeting()
  text "Age: " + toText(me.age)
  button "Birthday" -> me.birthday()
}
"""

S["struct_cart"] = """page "Cart"

struct Item {
  name: Text
  price: Int
  qty: Int

  fn lineTotal(): Int {
    return self.price * self.qty
  }

  fn more() {
    self.qty = self.qty + 1
  }
}

state cart: List<Item> = [
  Item(name: "Tea", price: 3, qty: 2),
  Item(name: "Cake", price: 5, qty: 1)
]

fn total(): Int {
  let sum = 0
  for i in cart { sum = sum + i.lineTotal() }
  return sum
}

view {
  heading "Your cart"
  for i in cart {
    row {
      text i.name + " x" + toText(i.qty) bold
      text "$" + toText(i.lineTotal())
    }
  }
  divider
  text "Total: $" + toText(total()) size 20 bold
  button "More tea" -> cart[0].more()
  button "More cake" -> cart[1].more()
}
"""

LIB_SHOP = """// shop.ternlib: shared logic. No drawing, no state.
struct Item {
  name: Text
  price: Int
  qty: Int
}

fn make(name: Text, price: Int): Item {
  return Item(name: name, price: price, qty: 1)
}

fn lineTotal(i: Item): Int {
  return i.price * i.qty
}

fn total(items: List<Item>): Int {
  let sum = 0
  for i in items { sum = sum + lineTotal(i) }
  return sum
}

fn money(n: Int): Text {
  return "$" + toText(n)
}
"""

S["lib_page"] = """page "Shop"

use "shop.ternlib"

state cart: List<shop.Item> = [shop.make("Tea", 3), shop.make("Cake", 5)]

fn addTea() {
  cart = append(cart, shop.make("Tea", 3))
}

view {
  heading "Your cart"
  for i in cart {
    row {
      text i.name
      text shop.money(shop.lineTotal(i))
    }
  }
  divider
  text "Total: " + shop.money(shop.total(cart)) bold size 20
  button "Add tea" -> addTea()
}
"""
LIBS_BY_SRC[S["lib_page"]] = {"shop": LIB_SHOP}

# a second page that reuses the same library
S["lib_second"] = """page "Receipt"

use "shop.ternlib"

state order: List<shop.Item> = [
  shop.Item(name: "Soup", price: 6, qty: 2),
  shop.make("Bread", 2)
]

view {
  heading "Receipt"
  for i in order {
    text i.name + ": " + shop.money(shop.lineTotal(i))
  }
  text "Pay " + shop.money(shop.total(order)) bold
}
"""
LIBS_BY_SRC[S["lib_second"]] = {"shop": LIB_SHOP}

# programs that should FAIL, with the phase we expect
BAD = {
    "e_types": ('state age: Int = 30\n\nview {\n  text "Age: " + age\n}\n', "type error"),
    "e_name": ('state count: Int = 0\n\nview {\n  text "Count: " + toText(cuont)\n}\n', "type error"),
    "e_ret": ('fn half(n: Int): Int {\n  if n > 0 {\n    return n / 2\n  }\n}\n\nview {\n  text toText(half(4))\n}\n', "type error"),
    "e_empty": ('view {\n  for x in [] {\n    text "hi"\n  }\n}\n', "type error"),
    "e_table": ('view {\n  table {\n    header "Name", "Qty"\n    cells "Tea"\n  }\n}\n', "type error"),
    "e_color": ('view {\n  text "Warning" color "red"\n}\n', "type error"),
    "e_mix": ('state n: Int = 2\n\nview {\n  text toText(n * 1.5)\n}\n', "type error"),
    "e_goto": ('view home {\n  button "Go" -> goto shop\n}\n', "type error"),
    "e_image": ('view {\n  image "lgo" width 100\n}\n', "type error"),
    "e_struct": ('struct Item {\n  name: Text\n  price: Int\n}\n\nview {\n  text Item(name: "Tea").name\n}\n', "type error"),
    "e_struct_pos": ('struct Item {\n  name: Text\n  price: Int\n}\n\nview {\n  text Item("Tea", 3).name\n}\n', "syntax error"),
    "e_loopvar": ('struct Item {\n  name: Text\n  qty: Int\n\n  fn more() {\n    self.qty = self.qty + 1\n  }\n}\n\nstate cart: List<Item> = [Item(name: "Tea", qty: 1)]\n\nview {\n  for i in cart {\n    button "More" -> i.more()\n  }\n}\n', "type error"),
    "e_selfret": ('struct Item {\n  qty: Int\n\n  fn next(): Int {\n    self.qty = self.qty + 1\n    return self.qty\n  }\n}\n\nview {\n  text "x"\n}\n', "type error"),
    "e_libfile": ('use "shop.ternlib"\n\nview {\n  text shop.money(5)\n}\n', "type error"),
    "e_lib": ('use "shop.ternlib"\n\nview {\n  text shop.totl(5)\n}\n', "syntax error"),
    "e_syntax": ('view {\n  heading "Oops"\n  text "No closing brace"\n', "syntax error"),
}
LIBS_BY_SRC[BAD["e_lib"][0]] = {"shop": LIB_SHOP}
LIBS_BY_SRC[BAD["e_libfile"][0]] = {"shop": LIB_SHOP.replace('return "$" + toText(n)', 'return "$" + n')}
RUNTIME = {
    "e_div": '''state zero: Int = 0
state result: Int = 0

view {
  button "Divide" -> result = 10 / zero
  text toText(result)
}
''',
}


# ---------------------------------------------------------------- helpers
# The playground itself is the test rig: samples are typed into the real page in a
# phone-sized browser, so screenshots and checks match what the reader will see.
import json
import subprocess
from playwright.sync_api import sync_playwright

INDEX = "file://" + os.path.join(os.path.dirname(OUT), "playground", "index.html")
_pw = sync_playwright().start()
_browser = _pw.chromium.launch()
FIT_CSS = ("body{height:auto} main{align-items:flex-start} .pane-page{flex:none} "
           ".paper{overflow:visible;flex:none}")


class Err:
    def __init__(self, d):
        self.phase, self.msg, self.pos, self.file = d["phase"], d["msg"], d["pos"], d.get("file")

    def __str__(self):
        return f"{self.phase}{' in ' + self.file if self.file else ''} at line {self.pos[0]}, column {self.pos[1]}: {self.msg}"


def libs_for(src):
    """Libraries (name -> source) that a sample page uses, registered in LIBS_BY_SRC."""
    return LIBS_BY_SRC.get(src, {})


def node_check(src):
    env = dict(os.environ, TERN_LIBS=json.dumps(libs_for(src)))
    out = subprocess.run(["node", os.path.join(OUT, "check.js")], input=src, capture_output=True,
                         text=True, check=True, env=env).stdout
    return json.loads(out)


def _open(src, width=390):
    ctx = _browser.new_context(viewport={"width": width, "height": 1500}, device_scale_factor=2)
    ctx.add_init_script("localStorage.setItem('tern.libs', %s)" % json.dumps(json.dumps(libs_for(src))))
    pg = ctx.new_page()
    pg.route("**/fonts.googleapis.com/**", lambda r: r.abort())
    pg.goto(INDEX)
    pg.fill("#code", src)
    pg.wait_for_timeout(250)
    pg.click("#tab-page")
    return ctx, pg


def _act(pg, actions):
    for a in actions:
        if a[0] == "click":
            for _ in range(a[2] if len(a) > 2 else 1):
                pg.locator(f'button.tbtn:text-is("{a[1]}")').first.click()
        elif a[0] == "link":
            pg.locator(f'a.tlink:text-is("{a[1]}")').first.click()
        elif a[0] == "type":
            pg.fill(f'input[data-name="{a[1]}"]', a[2])
    pg.wait_for_timeout(80)


def run(src, actions=(), width=390, shot_path=None):
    ctx, pg = _open(src, width)
    try:
        _act(pg, actions)
        text = pg.inner_text("#page")
        rterr = pg.inner_text("#rterr") if pg.is_visible("#rterr") else ""
        if shot_path:
            pg.add_style_tag(content=FIT_CSS)
            pg.wait_for_timeout(60)
            pg.locator(".pane-page").screenshot(path=shot_path)
        return text, rterr
    finally:
        ctx.close()


def addr_of(src, actions=()):
    ctx, pg = _open(src)
    try:
        _act(pg, actions)
        return pg.inner_text("#addr")
    finally:
        ctx.close()


def images_ok(src):
    ctx, pg = _open(src)
    try:
        pg.wait_for_timeout(200)
        return pg.evaluate("[...document.querySelectorAll('#page img')].map(e => e.complete && e.naturalWidth > 0 && !e.classList.contains('broken'))")
    finally:
        ctx.close()


def style_of(src, label, prop, actions=()):
    ctx, pg = _open(src)
    try:
        _act(pg, actions)
        return pg.evaluate("""([label, prop]) => {
            const el = [...document.querySelectorAll('#page *')].find(e => !e.children.length && e.textContent === label);
            return el ? getComputedStyle(el)[prop] : null; }""", [label, prop])
    finally:
        ctx.close()


def shot(name, actions=(), key=None, width=390):
    path = os.path.join(IMG, name + ".png")
    text, _ = run(S[key or name], actions, width, path)
    return path, text


def app_shot(name, src, tab, width=390, height=720):
    ctx = _browser.new_context(viewport={"width": width, "height": height}, device_scale_factor=2)
    ctx.add_init_script("localStorage.setItem('tern.libs', %s)" % json.dumps(json.dumps(libs_for(src))))
    pg = ctx.new_page()
    pg.route("**/fonts.googleapis.com/**", lambda r: r.abort())
    pg.goto(INDEX)
    pg.fill("#code", src)
    pg.wait_for_timeout(250)
    pg.click("#tab-" + tab)
    pg.evaluate("document.getElementById('code').scrollTop = 0")
    path = os.path.join(IMG, name + ".png")
    pg.screenshot(path=path)
    ctx.close()
    return path


def err_shot(name):
    src, phase = BAD[name]
    d = node_check(src)
    assert not d["ok"] and d["phase"] == phase, (name, d)
    path = os.path.join(IMG, name + ".png")
    run(src, (), 390, path)
    return path, Err(d)


def runtime_msg(name, label):
    _, rt = run(RUNTIME[name], [("click", label)])
    return rt


def validate():
    for k, v in S.items():
        d = node_check(v)
        assert d["ok"], (k, d)
    T = lambda k, acts=(): run(S[k], acts)[0]
    t = T("types"); assert "Sam is 30" in t and "Happy? true" in t and "Number of scores: 3" in t, t
    t = T("functions"); assert "Double 21 is 42" in t and "TERN!" in t, t
    t = T("grades"); assert "grade B" in t and "= 10" in t and "Row 2" in t, t
    assert "Count: 2" in T("counter", [("click", "+", 3), ("click", "-")])
    t = T("shopping", [("type", "draft", "  Bread "), ("click", "Add")]); assert "3. Bread" in t, t
    t = T("shopping", [("type", "draft", "Bread"), ("click", "Add"), ("click", "Remove")])
    assert "1. Eggs" in t and "2. Bread" in t, t
    guess = lambda v: [("type", "guess", v), ("click", "Submit")]
    t = T("quiz", guess("4") + guess("paris") + guess("no"))
    assert "Score: 2 out of 3" in t and "Not quite. The answer was yes." in t, t
    assert "Question 1" in T("quiz", guess("4") + guess("paris") + guess("no") + [("click", "Play again")])
    assert "Full name: Ada Lovelace" in T("ex1", [("type", "first", "Ada"), ("type", "last", "Lovelace")])
    assert "Count: 0" in T("ex2", [("click", "-"), ("click", "+", 2), ("click", "-", 5)])
    assert "One" not in T("ex3", [("click", "Clear all")])
    lines = T("ex4").split("\n")
    assert lines[0] == "1" and lines[2] == "Fizz" and lines[4] == "Buzz" and lines[14] == "FizzBuzz", lines
    # new chapters: check the real computed styles in the page
    assert style_of(S["style_text"], "Bigger", "fontSize") == "26.7px"
    assert style_of(S["style_text"], "Red and bold", "color") == "rgb(209, 36, 47)"
    assert style_of(S["style_text"], "Red and bold", "fontWeight") == "700"
    assert style_of(S["style_text"], "Centered", "textAlign") == "center"
    assert "line-through" in style_of(S["style_text"], "Struck through", "textDecorationLine")
    assert style_of(S["colors"], "From a state", "color") == "rgb(188, 76, 0)"
    assert style_of(S["colors"], "From a state", "color", [("click", "Purple")]) == "rgb(130, 80, 223)"
    assert style_of(S["colors"], "By hex", "color") == "rgb(11, 87, 208)"
    assert style_of(S["colors"], "By rgb", "color") == "rgb(200, 40, 120)"
    assert style_of(S["dyn"], "Write the report", "fontWeight") == "700"
    after = [("click", "Toggle done"), ("click", "Bigger", 2)]
    assert "line-through" in style_of(S["dyn"], "Write the report", "textDecorationLine", after)
    assert style_of(S["dyn"], "Write the report", "fontWeight", after) == "400"
    assert style_of(S["dyn"], "Write the report", "fontSize", after) == "24px"
    t = T("tables"); assert "Player" in t and "Grace" in t and "88" in t, t
    t = T("para"); assert "Tern is small, typed and friendly." in t and "Bread" in t, t
    assert style_of(S["styles"], "Heads up!", "backgroundColor") == "rgb(253, 236, 234)"
    assert style_of(S["styles"], "A bigger heads up!", "fontSize") == "26.7px"
    assert style_of(S["ex5"], "first program", "fontWeight") == "700"
    t = T("ex6"); assert "Total" in t and "$1320" in t, t
    for k, (src, phase) in BAD.items():
        d = node_check(src)
        assert not d["ok"] and d["phase"] == phase, (k, d)
        err_shot(k)
    t = T("nav_basic", [("click", "Open the shop")]); assert "Nothing for sale yet." in t, t
    assert addr_of(S["nav_basic"], [("click", "Open the shop")]).endswith("/shop")
    t = T("nav_basic", [("click", "Open the shop"), ("click", "Back")]); assert "opened the shop 1 time(s)" in t, t
    t = T("cafe", [("click", "Menu")]); assert "$2.50" in t and "$3.20" in t and "$4.00" in t, t
    assert addr_of(S["cafe"], [("click", "Menu"), ("click", "Back"), ("click", "About")]).endswith("/about")
    assert addr_of(S["cafe"], [("click", "About"), ("link", "Home")]).endswith("/home")
    assert all(images_ok(S["cafe"])) and all(images_ok(S["images"])) and len(images_ok(S["images"])) == 4
    assert style_of(S["buttons"], "Primary", "borderRadius") == "10px"
    assert style_of(S["buttons"], "Primary", "backgroundColor") == "rgb(11, 87, 208)"
    assert style_of(S["buttons"], "Wide button", "width") == "280px"
    assert style_of(S["buttons"], "Pill +5", "borderRadius") == "999px"
    assert style_of(S["box"], "Card title", "fontWeight") == "700"
    assert "Caveat" in style_of(S["fonts"], "hand: The quick brown fox", "fontFamily")
    assert "JetBrains" in style_of(S["fonts"], "Pick a font below", "fontFamily", [("click", "mono")])
    t = T("float"); assert "Total: $7.50" in t and "Rounded: 8" in t and "Half: 3.75" in t and "Price: 2.5" in t, t
    assert "Total: $8.25" in T("float", [("click", "Raise price")])
    t = T("tipcalc", [("type", "bill", "80"), ("click", "20%")]); assert "Tip (20%): $16.00" in t and "Total: $96.00" in t, t
    t = T("ex7", [("click", "Contact me")]); assert "hello@example.com" in t, t
    assert "Welcome" in T("ex7", [("click", "Contact me"), ("click", "Back")])
    assert "Each pays $30.00" in T("ex8", [("type", "bill", "90"), ("click", "+")])
    assert "Each pays $90.00" in T("ex8", [("type", "bill", "90"), ("click", "-"), ("click", "-")])
    # structs and libraries
    t = T("struct_basic"); assert "ada" in t.lower() and "Age: 36" in t, t
    assert "hello, ada" in t.lower()
    assert "Age: 38" in T("struct_basic", [("click", "Birthday", 2)])
    t = T("struct_cart"); assert "Tea x2" in t and "$6" in t and "Total: $11" in t, t
    t = T("struct_cart", [("click", "More tea")]); assert "Tea x3" in t and "Total: $14" in t, t
    t = T("lib_page"); assert "Total: $8" in t and "Tea" in t, t
    assert "Total: $11" in T("lib_page", [("click", "Add tea")])
    t = T("lib_second"); assert "Soup: $12" in t and "Bread: $2" in t and "Pay $14" in t, t
    assert "needs price: Int" in node_check(BAD["e_struct"][0])["msg"]
    assert "named fields" in node_check(BAD["e_struct_pos"][0])["msg"]
    assert "copy of a list item" in node_check(BAD["e_loopvar"][0])["msg"]
    assert "cannot change self" in node_check(BAD["e_selfret"][0])["msg"]
    d = node_check(BAD["e_lib"][0]); assert "has no 'totl'" in d["msg"], d
    d = node_check(BAD["e_libfile"][0]); assert d["file"] == "shop.ternlib" and "toText" in d["msg"], d
    rt = runtime_msg("e_div", "Divide")
    assert "runtime error" in rt and "division by zero" in rt, rt


validate()
print("all samples validated")

# ---------------------------------------------------------------- styles
ACCENT = colors.HexColor("#0b57d0")
INK = colors.HexColor("#1f2328")
MUTED = colors.HexColor("#6e7781")
ss = getSampleStyleSheet()
body = ParagraphStyle("Body", parent=ss["Normal"], fontName="Helvetica", fontSize=10.5, leading=15.5,
                      textColor=INK, spaceAfter=7)
h1 = ParagraphStyle("H1", parent=body, fontName="Helvetica-Bold", fontSize=22, leading=27,
                    textColor=ACCENT, spaceBefore=0, spaceAfter=12)
h2 = ParagraphStyle("H2", parent=body, fontName="Helvetica-Bold", fontSize=13.5, leading=18,
                    textColor=INK, spaceBefore=12, spaceAfter=5, keepWithNext=1)
cap = ParagraphStyle("Cap", parent=body, fontSize=8.5, leading=11, textColor=MUTED, alignment=TA_CENTER,
                     spaceBefore=3, spaceAfter=10)
cell = ParagraphStyle("Cell", parent=body, fontSize=9.2, leading=12.4, spaceAfter=0)
cellb = ParagraphStyle("CellB", parent=cell, fontName="Helvetica-Bold", textColor=colors.white)
codestyle = ParagraphStyle("Code", fontName="Courier", fontSize=8.4, leading=10.8, textColor=INK)
label = ParagraphStyle("Label", parent=body, fontName="Helvetica-Bold", fontSize=8.5, leading=11,
                       textColor=MUTED, spaceBefore=4, spaceAfter=2, keepWithNext=1)


def flat(items):
    out = []
    for i in items:
        if isinstance(i, (list, tuple)):
            out += flat(i)
        else:
            out.append(i)
    return out


def esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def fmt(t):
    t = esc(t)
    t = re.sub(r"`([^`]+)`", r'<font face="Courier" size="9.5" color="#a02c5a">\1</font>', t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", t)
    return t


def P(t, style=body):
    return Paragraph(fmt(t), style)


def H1(t):
    return Paragraph(esc(t), h1)


def H2(t):
    return Paragraph(esc(t), h2)


def bullets(items):
    rows = [[Paragraph("•", body), P(i)] for i in items]
    t = Table(rows, colWidths=[14, 6.4 * inch])
    t.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"), ("LEFTPADDING", (0, 0), (-1, -1), 2),
                           ("TOPPADDING", (0, 0), (-1, -1), 0), ("BOTTOMPADDING", (0, 0), (-1, -1), 3)]))
    return t


def code(src, title=None):
    src = src.rstrip("\n")
    t = Table([[Preformatted(src, codestyle)]], colWidths=[6.7 * inch])
    t.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), colors.HexColor("#f6f8fa")),
                           ("BOX", (0, 0), (-1, -1), 0.6, colors.HexColor("#d0d7de")),
                           ("LEFTPADDING", (0, 0), (-1, -1), 10), ("TOPPADDING", (0, 0), (-1, -1), 8),
                           ("BOTTOMPADDING", (0, 0), (-1, -1), 8)]))
    parts = ([Paragraph(esc(title), label)] if title else []) + [t, Spacer(1, 8)]
    return parts


def callout(kind, text):
    col = {"Tip": "#1a7f37", "Watch out": "#b3261e", "Note": ACCENT.hexval().replace("0x", "#")}[kind]
    bg = {"Tip": "#eef8f0", "Watch out": "#fdf0ef", "Note": "#eef3fc"}[kind]
    t = Table([[Paragraph(f'<b><font color="{col}">{kind}.</font></b> ' + fmt(text), cell)]],
              colWidths=[6.7 * inch])
    t.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), colors.HexColor(bg)),
                           ("LINEBEFORE", (0, 0), (0, -1), 3, colors.HexColor(col)),
                           ("LEFTPADDING", (0, 0), (-1, -1), 10), ("TOPPADDING", (0, 0), (-1, -1), 7),
                           ("BOTTOMPADDING", (0, 0), (-1, -1), 7)]))
    return [t, Spacer(1, 9)]


def table(header, rows, widths):
    data = [[Paragraph(esc(h), cellb) for h in header]] + [[Paragraph(fmt(c), cell) for c in r] for r in rows]
    t = Table(data, colWidths=[w * inch for w in widths], repeatRows=1)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), ACCENT), ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#f6f8fa")]),
        ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#d0d7de")),
        ("TOPPADDING", (0, 0), (-1, -1), 4), ("BOTTOMPADDING", (0, 0), (-1, -1), 4)]))
    return [t, Spacer(1, 10)]


def img_row(items, w=2.25):
    cells = []
    for path, cap_ in items:
        iw, ih = PILImage.open(path).size
        ww = w * inch
        cells.append([Image(path, width=ww, height=ww * ih / iw), Paragraph(esc(cap_), cap)])
    t = Table([cells], colWidths=[(w + 0.2) * inch] * len(items))
    t.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP")]))
    t.hAlign = "CENTER"
    return KeepTogether([t])


def img(path, caption, w=3.1 * inch):
    iw, ih = PILImage.open(path).size
    im = Image(path, width=w, height=w * ih / iw)
    t = Table([[im]], colWidths=[w + 4])
    t.setStyle(TableStyle([("BOX", (0, 0), (-1, -1), 0.6, colors.HexColor("#d0d7de")),
                           ("LEFTPADDING", (0, 0), (-1, -1), 2), ("RIGHTPADDING", (0, 0), (-1, -1), 2),
                           ("TOPPADDING", (0, 0), (-1, -1), 2), ("BOTTOMPADDING", (0, 0), (-1, -1), 2)]))
    t.hAlign = "CENTER"
    return KeepTogether([t, Paragraph(esc(caption), cap)])


# ---------------------------------------------------------------- document
class Doc(BaseDocTemplate):
    def afterFlowable(self, fl):
        if isinstance(fl, Paragraph) and fl.style.name == "H1":
            self.notify("TOCEntry", (0, fl.getPlainText(), self.page))


def footer(canv, doc):
    canv.saveState()
    canv.setFont("Helvetica", 8.5)
    canv.setFillColor(MUTED)
    canv.drawString(0.9 * inch, 0.55 * inch, "Learn Tern")
    canv.drawRightString(letter[0] - 0.9 * inch, 0.55 * inch, str(doc.page))
    canv.restoreState()


def cover(canv, doc):
    canv.saveState()
    w, h = letter
    canv.setFillColor(ACCENT)
    canv.rect(0, h - 4.6 * inch, w, 4.6 * inch, stroke=0, fill=1)
    canv.setFillColor(colors.white)
    canv.setFont("Helvetica-Bold", 54)
    canv.drawString(0.9 * inch, h - 2.5 * inch, "Learn Tern")
    canv.setFont("Helvetica", 17)
    canv.drawString(0.9 * inch, h - 3.1 * inch, "Build web pages with a small, strongly typed language")
    canv.drawString(0.9 * inch, h - 3.5 * inch, "No HTML. No JavaScript. No TypeScript.")
    canv.setFillColor(INK)
    canv.setFont("Helvetica", 12)
    canv.drawString(0.9 * inch, h - 5.4 * inch, "A beginner's guide, with exercises and a complete project")
    canv.setFillColor(MUTED)
    canv.setFont("Helvetica", 10)
    canv.drawString(0.9 * inch, 0.9 * inch, "Covers Tern 0.3, with structs and libraries. Every example in this guide was run through the real Tern checker.")
    canv.restoreState()


doc = Doc(os.path.join(OUT, "Learn_Tern.pdf"), pagesize=letter, title="Learn Tern",
          author="Tern", subject="A beginner's guide to the Tern language",
          leftMargin=0.9 * inch, rightMargin=0.9 * inch, topMargin=0.8 * inch, bottomMargin=0.9 * inch)
frame = Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id="f")
doc.addPageTemplates([PageTemplate("cover", [frame], onPage=cover, autoNextPageTemplate="main"),
                      PageTemplate("main", [frame], onPage=footer)])

story = [Spacer(1, 6 * inch), PageBreak()]

toc = TableOfContents()
toc.levelStyles = [ParagraphStyle("t0", parent=body, fontSize=11.5, leading=22, leftIndent=0)]
story += [H1("Contents"), toc, PageBreak()]

# ---- 1
def app_row():
    p1 = app_shot("app_code", S["counter"], "code", height=640)
    p2 = app_shot("app_page", S["counter"], "page", height=640)
    cells = []
    for path, cap_ in [(p1, "The Code tab"), (p2, "The Page tab")]:
        iw, ih = PILImage.open(path).size
        w = 2.3 * inch
        cells.append([Image(path, width=w, height=w * ih / iw), Paragraph(cap_, cap)])
    t = Table([cells], colWidths=[2.5 * inch] * 2)
    t.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP")]))
    t.hAlign = "CENTER"
    return KeepTogether([t])


story += [H1("1. What is Tern?"),
          P("Tern is a small language for describing web pages. A Tern page is a plain text file that says "
            "what information the page remembers, what it can do, and what it looks like. "
            "You write it in the Tern Playground, a page that works on a phone, a tablet or a computer, and the page appears as you type. There is no HTML to write, no JavaScript, and nothing to install."),
          P("Tern is **strongly typed**. Every value has a type such as `Int` or `Text`, and Tern checks "
            "that you use values correctly before the page ever runs. If you try to add a number to a "
            "sentence, you get a clear error message instead of a page that quietly misbehaves."),
          H2("The three parts of a page"),
          bullets(["**state**: the things the page remembers, like a counter or a list of tasks.",
                   "**fn** (functions): the things the page can do, like adding an item.",
                   "**view**: what the page looks like, written in terms of the state."]),
          P("When you click a button or type in a box, Tern changes the state and then redraws the view. "
            "That one idea, **state changes, view redraws**, is the whole mental model."),
          code("""state count: Int = 0              // remembered

fn bump() { count = count + 1 }   // can change what is remembered

view {                            // always shows the current state
  text "Clicked " + toText(count) + " times"
  button "Click me" -> bump()
}""", "The shape of every Tern page"),
          H2("What you need"),
          P("Only the **Tern Playground**. It has four tabs along the top:"),
          bullets(["**Code**: where you type. A row of keys above the editor holds the characters that are awkward "
                   "on a phone keyboard (braces, quote marks, the arrow), and an Insert menu adds ready-made blocks "
                   "such as a button or a table.",
                   "**Page**: the page you are building. It updates as you type.",
                   "**Images**: sample pictures, and a button to add your own photos (chapter 15).",
                   "**Help**: a cheat sheet you can keep open while you write."]),
          P("Pick any example from the menu at the top, change it, and watch the page change. "
            "**Reset** puts the example back as it was."),
          app_row(),
          CondPageBreak(3.6 * inch)]

# ---- 2
p, _ = shot("hello")
story += [H1("2. Your first page"),
          code(S["hello"], "hello.tern"),
          img(p, "The page made by hello.tern"),
          H2("What each line does"),
          bullets(["`page \"Hello\"` gives the page a title (shown in the address bar). It is optional.",
                   "`view { ... }` holds everything the page shows. Every page needs exactly one.",
                   "`heading` shows large text. `text` shows normal text.",
                   "Text goes in double quotes. Inside quotes, `\\n` is a new line, `\\t` a tab, "
                   "`\\\"` a quote mark and `\\\\` a backslash.",
                   "Anything after `//` on a line is a comment, ignored by Tern."]),
          *callout("Tip", "There are no semicolons and no commas between lines. Put each statement or "
                          "element on its own line."),
          H2("Try it"),
          P("Open the playground, pick any example, and replace its code with the page above. Change the heading "
            "and add a second `text` line, then switch to the Page tab to see it."),
          CondPageBreak(3.6 * inch)]

# ---- 3
p, _ = shot("types")
story += [H1("3. Types and state"),
          H2("The types"),
          *table(["Type", "Holds", "Examples"],
                 [["`Int`", "whole numbers", "`0`, `42`, `-7`"],
                  ["`Text`", "words and sentences", "`\"hello\"`, `\"\"`"],
                  ["`Bool`", "yes or no", "`true`, `false`"],
                  ["`List<T>`", "an ordered list of values that are all type T",
                   "`[1, 2, 3]`, `[\"a\", \"b\"]`"],
                  ["`Color`", "a colour for text or backgrounds (chapter 9)", "`red`, `#0b57d0`"],
                  ["`Align`", "where text sits: `left`, `center` or `right`", "`center`"],
                  ["`Float`", "numbers with decimals (chapter 16)", "`2.5`, `0.0`"],
                  ["`Font`", "a typeface (chapter 14)", "`serif`, `mono`"]], [1.1, 2.9, 2.7]),
          P("`Int` is for whole numbers, and division of `Int` values rounds down: `7 / 2` is `3`. For decimals use `Float`, "
            "which is a different type (chapter 16)."),
          H2("State"),
          P("A `state` line declares something the page remembers. It always has a name, a type, and a "
            "starting value:"),
          code(S["types"], "types.tern"),
          img(p, "Four kinds of state, shown with toText()"),
          *callout("Watch out", "Tern never converts types for you. `\"Age: \" + age` is an error because "
                                "`age` is an `Int`. Write `\"Age: \" + toText(age)` instead. `toText` works on "
                                "`Int`, `Bool` and `Text`."),
          CondPageBreak(3.6 * inch)]

# ---- 3b counter
p, _ = shot("counter_after", [("click", "+", 3), ("click", "-")], key="counter")
story += [H1("4. Making pages respond"),
          P("A **button** runs an action when clicked. The action follows an arrow `->`. "
            "It can change state, or call a function."),
          code(S["counter"], "counter.tern"),
          img(p, "counter.tern after clicking + three times and - once"),
          P("`count = count + 1` is an **assignment**: it replaces the value of `count`. Tern checks that the "
            "new value has the right type, so `count = \"five\"` is rejected before the page runs."),
          P("Several buttons can sit side by side inside a `row`. Use `column` to stack things vertically "
            "(that is also what the page does by default)."),
          H2("Text boxes"),
          P("An `input` is a text box wired to a `Text` state. Whatever the person types is stored in that "
            "state, and the view updates as they type."),
          code("state name: Text = \"\"\n\nview {\n  input name placeholder \"Your name\"\n"
               "  text \"Hello, \" + name\n}"),
          *callout("Note", "The name after `input` must be a state of type `Text`. Tern reports an error "
                           "if it is missing or is a different type."),
          P("`input` can also edit one item of a list, or a `Text` field of a struct in a list: `input names[i]`, "
            "`input people[i].name`. It can be a table cell too. The place must start at a state, not at a loop variable "
            "(a loop variable is only a copy), so loop over `range(len(xs))` and use the index."),
          H2("Checkboxes"),
          P("A `checkbox` shows a `Bool`. Name a `Bool` state and tapping the box flips it: `checkbox agree \"I agree\"`. "
            "To tick one item in a list, give the checkbox any `Bool` and an action: "
            "`checkbox picked[i] \"Pick\" -> picked = setAt(picked, i, !picked[i])`. A checkbox can also be a table cell."),
          H2("Dropdowns and radio buttons"),
          P("`select` shows a dropdown and `radio` shows every choice at once. Both pick from a list of `Text` options and store the "
            "choice in a `Text` state, or in a place inside one, like `input`: `select country in countries placeholder \"Country\"` and "
            "`radio plan in [\"Free\", \"Pro\"]`. If the stored text is not one of the options, nothing is selected. "
            "A `select` can also be a table cell: `cells select members[i].role in roles`."),
          H2("Multi-line text, sliders and disabled controls"),
          P("`textarea notes placeholder \"Notes\" height 120` is a multi-line text box on a `Text` state (or a place inside one); `height` and `width` size it. "
            "`slider volume in 0 to 100` edits an `Int` between two numbers: a state outside the range is shown at the nearest end, "
            "and a range that ends before it starts is a runtime error. Write `disabled` (optionally `disabled when cond`) on a button, "
            "text box, textarea, slider, dropdown, radio or checkbox to grey it out. A disabled control does nothing when it is used, "
            "for example `button \"Send\" disabled when !agreed -> sent = true`."),
          H2("Saved state"),
          P("Put `saved` in front of a `state` and its value is kept between visits: `saved state laps: List<Int> = []`. States without "
            "`saved` start fresh each time. Any type works, including lists and structs. If a kept value no longer fits the type the state "
            "now has, it is ignored and the initial value is used. Each page keeps up to 64 KB on this device, only the page itself can read it, "
            "and it is never sent anywhere. The playground has a Clear saved button in the page bar; Tern Browser has Clear Saved Data "
            "for This Page in the View menu."),
          H2("Timers"),
          P("`every 1000 when running -> seconds = seconds + 1` runs the action every 1000 milliseconds while the page is showing and "
            "`running` is true. The time is an `Int` in milliseconds. A timer never ticks faster than every 100 ms, a page can have at most "
            "four at once, it pauses while the browser tab or the app is in the background, and it stops when you go to another `view`. "
            "If its action fails three times in a row, the timer stops and the error is shown."),
          H2("Dialogs"),
          P("A `modal` is drawn over the page while its `Bool` is true. The page behind it is dimmed and cannot be tapped. "
            "Tapping the dim area, or pressing Escape, closes it: on a plain `Bool` state that sets the state to false, "
            "and with `-> action` it runs your action instead. A modal goes directly in the view, not inside a row or column. "
            "It takes `width`, `background`, `padding`, `radius` and `border`."),
          code("state confirm: Bool = false\n\nbutton \"Delete\" -> confirm = true\nmodal confirm width 300 {\n  heading \"Delete it?\"\n  button \"Cancel\" -> confirm = false\n}\n", "A dialog"),
          CondPageBreak(3.6 * inch)]

# ---- 5 functions
p, _ = shot("functions")
story += [H1("5. Functions"),
          P("A function packages up some work under a name. You list each **parameter** with its type, and "
            "after the parentheses you write the type of the value it hands back."),
          code(S["functions"], "functions.tern"),
          img(p, "functions.tern", w=2.9 * inch),
          H2("Rules worth knowing"),
          bullets(["`fn name(a: Int, b: Text): Text { ... }` takes two parameters and returns `Text`.",
                   "Leave off `: Type` when a function returns nothing. Such a function is usually called "
                   "from a button.",
                   "A function that promises a type must `return` a value on **every** path. Tern checks this.",
                   "Parameters and `let` variables are local to the function. `state` is visible everywhere.",
                   "Functions can call each other and themselves (recursion), in any order in the file.",
                   "`let total = 0` creates a local variable. Its type is worked out from the value. "
                   "Add a type when you need to: `let xs: List<Int> = []`."]),
          *callout("Tip", "Give small jobs their own function. `button \"Add\" -> add()` reads much better "
                          "than five lines of assignments inside the button."),
          CondPageBreak(3.6 * inch)]

# ---- 6 decisions loops
p, _ = shot("grades")
pfe, _ = shot("foreach_demo")
story += [H1("6. Decisions and loops"),
          code(S["grades"], "grades.tern"),
          img(p, "grades.tern", w=2.9 * inch),
          H2("if / else"),
          P("The condition must be a `Bool`. Writing `if 1 { ... }` is a type error, because 1 is not true or false. "
            "Chain choices with `else if`."),
          H2("Comparing and combining"),
          *table(["Kind", "Operators"],
                 [["Compare any two values of the same type", "`==`   `!=`"],
                  ["Compare numbers", "`<`   `>`   `<=`   `>=`"],
                  ["Combine yes/no values", "`&&` (and)   `||` (or)   `!` (not)"],
                  ["Arithmetic on `Int`", "`+`   `-`   `*`   `/` (rounds down)   `%` (remainder)"],
                  ["Join `Text`, or join two lists", "`+`"]], [3.0, 3.7]),
          H2("for and foreach loops"),
          P("`for x in xs { ... }` (or `foreach x in xs { ... }`) runs the block once per item of a list. "
            "`foreach` means the same thing as `for`. To repeat something a number of times, loop over "
            "`range(n)`, which is the list `[0, 1, ..., n-1]`. There is no `while` loop, so a Tern page "
            "cannot get stuck looping forever."),
          code(S["foreach_demo"], "foreach_demo.tern"),
          img(pfe, "foreach_demo.tern, drawn with foreach", w=2.9 * inch),
          CondPageBreak(3.6 * inch)]

# ---- 7 view
p, _ = shot("profile", [("type", "name", "Sam"), ("click", "Subscribe")])
story += [H1("7. Building the view"),
          *table(["Element", "What it does"],
                 [["`heading expr`", "Large text. The expression must be `Text`."],
                  ["`text expr`", "Normal text."],
                  ["`button expr -> action`", "A button. The action is one statement, or a `{ block }`."],
                  ["`input name placeholder expr`", "A text box bound to a `Text` state. The placeholder is optional."],
                  ["`modal flag { ... }`", "A dialog drawn over the page while the `Bool` is true. Tapping the dim area or pressing Escape closes it."],
                  ["`textarea place`", "A multi-line text box on a `Text` state; `height`, `width`, optional `placeholder`."],
                  ["`slider place in low to high`", "A slider that edits an `Int` between low and high."],
                  ["`saved state name: T = value`", "A state whose value is kept between visits (up to 64 KB per page)."],
                  ["`every ms when cond -> action`", "Run an action every `ms` milliseconds (at least 100) while the page shows and the condition is true."],
                  ["`select place in options`", "A dropdown that stores the chosen `Text`; optional `placeholder`."],
                  ["`radio place in options`", "Radio buttons that store the chosen `Text`."],
                  ["`checkbox flag \"label\"`", "A checkbox bound to a `Bool` state; or `checkbox expr \"label\" -> action`."],
                  ["`row { ... }` / `column { ... }`", "Lay children out side by side, or stacked."],
                  ["`if cond { ... } else { ... }`", "Show different things depending on state."],
                  ["`for x in list { ... }`", "Repeat elements, one per list item. `foreach` works the same way."],
                  ["`link text to address`", "A link to a web address. Use `link text -> goto page` to move inside your own site."],
                  ["`image expr`", "A picture (chapter 15)."],
                  ["`para { span ... }`", "A paragraph with mixed styles (chapter 10)."],
                  ["`bullet expr`", "A bulleted line."],
                  ["`table height 240 { ... }`", "A table; with height it scrolls in a box, header fixed (chapter 10)."],
                  ["`divider`", "A thin horizontal line."]], [2.4, 4.3]),
          code(S["profile"], "profile.tern"),
          img(p, "profile.tern after typing a name and clicking Subscribe", w=2.9 * inch),
          P("Inside a view, `if`, `for` and `foreach` choose and repeat **elements**. Inside a function or button action, "
            "they choose and repeat **statements**. The words are the same, and the contents differ."),
          CondPageBreak(3.6 * inch)]

# ---- 8 lists
p, _ = shot("shopping_after", [("type", "draft", "Bread"), ("click", "Add")], key="shopping")
story += [H1("8. Lists"),
          P("A list holds any number of values of one type. Count from zero: the first item is `xs[0]`."),
          *table(["Code", "Result"],
                 [["`[10, 20, 30]`", "a `List<Int>`"],
                  ["`xs[1]`", "the item at position 1 (counting from 0)"],
                  ["`len(xs)`", "how many items (also works on `Text`)"],
                  ["`append(xs, 5)`", "a **new** list with 5 added at the end"],
                  ["`removeAt(xs, 0)`", "a **new** list without the item at position 0"],
                  ["`setAt(xs, 1, 9)`", "a **new** list with position 1 replaced by 9"],
                  ["`slice(xs, 1, 3)`", "a **new** list of positions 1 and 2 (never fails if the range runs past the end)"],
                  ["`sort(xs)`", "a **new** list, smallest first (`Int`, `Float` or `Text` lists)"],
                  ["`sortOrder(xs)`", "the positions of `xs` in sorted order, so one list can sort another"],
                  ["`reverse(xs)`", "a **new** list, back to front"],
                  ["`range(4)`", "`[0, 1, 2, 3]`"],
                  ["`join([\"a\", \"b\"], \", \")`", "`\"a, b\"`"]], [2.4, 4.3]),
          P("Lists never change in place. `append` and `removeAt` return a new list, so you store the result "
            "back into your state: `items = append(items, \"Bread\")`."),
          code(S["shopping"], "shopping.tern"),
          img(p, "shopping.tern after adding Bread", w=2.8 * inch),
          *callout("Watch out", "Index outside a list, as in `xs[5]` when it has 3 items, causes a runtime "
                                "error. Tern shows it in the status bar and keeps the page running. An empty "
                                "list `[]` needs a known type: `state xs: List<Int> = []`."),
          CondPageBreak(3.6 * inch)]

# ---- 9 styling
p_a, _ = shot("style_text")
p_b, _ = shot("colors_after", [("click", "Purple")], key="colors")
p_c, _ = shot("dyn_after", [("click", "Toggle done"), ("click", "Bigger", 2)], key="dyn")
story += [CondPageBreak(4 * inch), H1("9. Styling text"),
          P("So far every page has used one plain look. To change how a piece of text looks, add words after it. "
            "The order does not matter, and you can add as many as you like."),
          code(S["style_text"], "style_text.tern"),
          img(p_a, "Every kind of text style", w=2.9 * inch),
          *table(["Add this", "To get"],
                 [["`size 20`", "bigger or smaller text, in points. Normal text is 12; a heading is 22."],
                  ["`bold`   `italic`   `underline`   `strike`", "that effect"],
                  ["`color red`", "coloured text"],
                  ["`background #fff3bf`", "a highlight behind the text"],
                  ["`align center`", "`left`, `center` or `right`"]], [2.5, 4.2]),
          H2("Colours"),
          P("A colour can be a name, a hex code such as `#0b57d0` (or the short form `#fff`), or `rgb(r, g, b)` "
            "with each part from 0 to 255. The names are `black white gray red green blue orange purple yellow pink`."),
          code(S["colors"], "colors.tern"),
          img(p_b, "colors.tern after tapping Purple", w=2.9 * inch),
          *callout("Watch out", "`Color` is a type, like `Int`. The word `red` is a colour, but `\"red\"` in "
                                "quotes is `Text`, and Tern will tell you so: `color \"red\"` is an error."),
          H2("Styles that change"),
          P("Every number and flag in a style can come from state, so the style follows the page. "
            "Put `when` after `bold`, `italic`, `underline` or `strike` to switch it on only while a condition is true. "
            "`size` and `color` take any expression of the right type."),
          code(S["dyn"], "dyn.tern"),
          img(p_c, "After tapping Toggle done, then Bigger twice", w=2.9 * inch),
          H2("What can be styled"),
          P("Text, headings and bullets take everything above. A `button` takes size, bold, italic, color and "
            "background. A `link` takes size, bold, italic, strike and color. A `row` or `column` takes "
            "`background` and `padding`. Asking for something an element cannot have is a type error, for example "
            "\"a button cannot have 'align'\"."),
          CondPageBreak(3.6 * inch)]

# ---- 10 para/lists/tables
p_d, _ = shot("para")
p_e, _ = shot("tables")
pt, et = err_shot("e_table")
story += [H1("10. Mixed text, lists and tables"),
          H2("Mixing styles in one sentence"),
          P("A `para` holds `span` pieces that flow together as one paragraph. Settings on the `para` are shared by "
            "every span, and a span can change them for itself. A `bullet` is a single bulleted line."),
          code(S["para"], "para.tern"),
          img(p_d, "A mixed paragraph and a bullet list", w=2.9 * inch),
          H2("Tables"),
          P("A `table` has an optional `header` line and any number of `cells` lines. Separate the cells with commas. "
            "Use `for` and `if` inside a table to build rows from your lists."),
          code(S["tables"], "tables.tern"),
          img(p_e, "A table filled from two lists", w=2.9 * inch),
          bullets(["Cells are `Text`. Use `toText()` for numbers.",
                   "The `header`, if there is one, comes first and appears once.",
                   "Every row must have the same number of cells. Tern checks this before the page runs.",
                   "A table wider than the screen scrolls sideways. For a long table, write `table height 240 { ... }`: "
                   "it then scrolls up and down in its own box (240 points tall) and the header row stays in view.",
                   "A cell can be a `button` or a `link` (so a header can sort, and a first column can pick rows), and `span 2` "
                   "makes a cell cover two columns. Style words after a cell, like `bold` or `background #eef`, apply to that cell.",
                   "The table itself takes `padding`, `size`, `color`, `background`, `border` and `font`.",
                   "Write `table resizable { ... }` and the reader can drag the right edge of a header cell to change that "
                   "column's width. The widths last until the page is reloaded."]),
          code(BAD["e_table"][0], "A row with too few cells"),
          img(pt, f"Tern says: {et.msg}", w=2.9 * inch),
          CondPageBreak(3.6 * inch)]

# ---- 11 named styles
p_f, _ = shot("styles")
story += [H1("11. Named styles"),
          P("If you keep repeating the same settings, give them a name. A `style` goes at the top of the page, "
            "and then any element can use it with `style name`."),
          code(S["styles"], "styles.tern"),
          img(p_f, "Four styles, used in five places", w=2.9 * inch),
          H2("How styles combine"),
          bullets(["List several names to use them together: `style title note`. Later ones win if they disagree.",
                   "Settings written directly on the element win over a style, in the order you write them. "
                   "`style warning size 20` is the warning style, but bigger.",
                   "A style can hold any property. When you use it on an element, properties that element cannot "
                   "have are simply ignored, so one style can serve text and cards alike.",
                   "A style cannot use another style. Keep each one small and combine them on the element."]),
          *callout("Tip", "Name styles by what they mean (`warning`, `note`, `card`), not by how they look "
                          "(`red`). Then you can change the look in one place later."),
          CondPageBreak(3.6 * inch)]

# ---- 12-16 new in 0.3
n1, _ = shot("nav_home", key="nav_basic")
n2, _ = shot("nav_shop", [("click", "Open the shop")], key="nav_basic")
c1, _ = shot("cafe_home", key="cafe")
c2, _ = shot("cafe_menu", [("click", "Menu")], key="cafe")
g_path, g_err = err_shot("e_goto")
story += [CondPageBreak(4 * inch), H1("12. Pages and navigation"),
          P("Until now a page had one `view`. Give a view a name and you can have as many as you like. The first one is "
            "where the page starts. A button moves to another page with `goto`, and `back` returns to the page you "
            "came from."),
          code(S["nav_basic"], "nav_basic.tern"),
          img_row([(n1, "The home page"), (n2, "After tapping the button")]),
          bullets(["`goto shop` shows the page called `shop`. The name must match a `view shop { ... }`, and Tern checks it.",
                   "`back` goes to the page you came from. On the first page it does nothing.",
                   "A button can do several things in braces, such as changing state and then moving on.",
                   "A view with no name, `view { ... }`, is called `home`.",
                   "All pages share the same state, so what one page changes, the next page can show."]),
          H2("A small site"),
          P("Pages mix with everything else in this guide: images, fonts, tables and styled buttons."),
          code(S["cafe"], "cafe.tern"),
          img_row([(c1, "The home page"), (c2, "The menu page")]),
          H2("Links"),
          P("A `link` can move between pages too: `link \"Home\" -> goto home`. To open a web address, write "
            "`link \"Our website\" to \"https://example.com\"`. In the playground, the round arrow beside the address "
            "does the same as `back`."),
          H2("Typos are caught"),
          code(BAD["e_goto"][0], "A page that does not exist"),
          img(g_path, f"Tern says: {g_err.msg}", w=2.9 * inch),
          CondPageBreak(3.6 * inch)]

b1, _ = shot("buttons_shot", key="buttons")
bx, _ = shot("box_shot", key="box")
story += [CondPageBreak(4 * inch), H1("13. Buttons and boxes in style"),
          P("Yes, buttons can be styled. They take the same words as text, plus a few that make them look like buttons."),
          *table(["Add this", "To get"],
                 [["`background blue`", "the button colour"],
                  ["`color white`", "the label colour"],
                  ["`size 16`   `bold`   `italic`", "label size and weight"],
                  ["`font serif`", "the label font (chapter 14)"],
                  ["`padding 12`", "space around the label, in pixels"],
                  ["`radius 10`", "rounded corners. A big number such as 999 makes a pill"],
                  ["`border blue`", "a thin outline"],
                  ["`width 280`", "a fixed width in pixels"]], [2.5, 4.2]),
          code(S["buttons"], "buttons.tern"),
          img(b1, "Four named styles, and a button that changes while you use it", w=2.9 * inch),
          P("Notice `bold when on` on the Toggle button: like text, a button's bold, italic and strike can depend on state. "
            "That is how you make a selected option look different."),
          H2("Boxes"),
          P("A `row` or `column` can have a `background`, `padding`, `radius`, `border` and `width`, which turns it into a card."),
          code(S["box"], "box.tern"),
          img(bx, "A column styled as a card", w=2.6 * inch),
          H2("Spacing, alignment and grids"),
          P("A `row` or `column` takes `gap` (space between its items, default 8). Any block takes `margin` (space around it). "
            "On a `row`, `align` places the items: `left`, `center`, `right` or `spread`, which pushes them to opposite ends, like a menu bar. "
            "On a `column`, `align` places each item inside it left, centre or right. To put a narrow card in the middle of the page, "
            "wrap it in an outer `column align center`."),
          P("`grow N` makes a block in a row take N shares of the width that is left, so two columns can be one part and three parts. "
            "`maxwidth` and `minwidth` limit how wide a block gets. A `grid 3 { ... }` lays its items out in three equal columns, "
            "wrapping to new lines, with its own `gap`."),
          code("row align spread { text \"Shop\"  text \"Cart\" }\n\nrow gap 12 {\n  column grow 1 { text \"Side\" }\n  column grow 3 { text \"Main\" }\n}\n\ngrid 3 gap 10 {\n  for i in range(6) { text \"Card \" + toText(i) }\n}\n\ncolumn align center {\n  column maxwidth 360 padding 12 background #f6f8fa { text \"Centered card\" }\n}\n", "Layout"),
          CondPageBreak(3.6 * inch)]

f1, _ = shot("fonts_shot", [("click", "hand")], key="fonts")
story += [CondPageBreak(4 * inch), H1("14. Fonts"),
          P("Add `font` to any text, heading, bullet, paragraph, span, link or button. There are six to choose from."),
          *table(["Name", "Feel", "Good for"],
                 [["`sans`", "clean, the default", "body text"],
                  ["`serif`", "bookish", "articles and quotes"],
                  ["`mono`", "fixed width", "code and numbers"],
                  ["`display`", "elegant headline face", "big titles"],
                  ["`hand`", "handwriting", "notes and signatures"],
                  ["`rounded`", "soft and friendly", "buttons and labels"]], [1.2, 2.6, 2.9]),
          code(S["fonts"], "fonts.tern"),
          img(f1, "After tapping hand", w=2.9 * inch),
          P("`Font` is a type like `Color`, so a state can hold one (`state pick: Font = serif`) and a named style can "
            "include one. Fonts are fetched from the web the first time a page uses them. If a font cannot load, "
            "the browser shows a similar one instead."),
          CondPageBreak(3.6 * inch)]

i1, _ = shot("images_shot", key="images")
i2 = app_shot("images_tab", S["images"], "images", height=700)
ie_path, ie_err = err_shot("e_image")
story += [CondPageBreak(4 * inch), H1("15. Images"),
          P("An `image` shows a picture by name. Four sample pictures come with the playground (`mountains`, `sunset`, "
            "`avatar` and `logo`), and you can add your own."),
          code(S["images"], "images.tern"),
          img_row([(i1, "The page"), (i2, "The Images tab")], w=2.3),
          *table(["Add this", "To get"],
                 [["`width 300`   `height 64`", "a size in pixels. Give only the width and the height follows"],
                  ["`radius 12`", "rounded corners. `radius 999` on a square image makes a circle"],
                  ["`border gray`", "a thin outline"],
                  ["`align center`", "`left`, `center` or `right`"],
                  ["`alt \"text\"`", "a description, used if the picture cannot show"]], [2.5, 4.2]),
          H2("Adding your own photos"),
          bullets(["Open the **Images** tab and tap **Add a photo**. Pick one from your phone.",
                   "The photo is shrunk to a sensible size and named after its file, such as `team-photo`. "
                   "It stays on this device only.",
                   "Tap **Use in page** to drop `image \"team-photo\" width 240` into your code.",
                   "**Remove** takes it away again."]),
          H2("Name checking"),
          P("Tern checks the name of every picture you write in quotes, and lists the ones you have."),
          code(BAD["e_image"][0], "A misspelled picture name"),
          img(ie_path, f"Tern says: {ie_err.msg}", w=2.9 * inch),
          P("A picture name can also come from state, as in `state pic: Text = \"logo\"` and `image pic`, which is a "
            "good way to let a button change the picture."),
          CondPageBreak(3.6 * inch)]

d1, _ = shot("float_after", [("click", "Raise price")], key="float")
d2, _ = shot("tip_after", [("type", "bill", "80"), ("click", "20%")], key="tipcalc")
em_path, em_err = err_shot("e_mix")
story += [CondPageBreak(4 * inch), H1("16. Decimal numbers"),
          P("`Float` holds numbers with decimals, written with a point: `2.5`, `0.0`, `100.0`. A `Float` is a different "
            "type from an `Int`, so Tern never mixes them by accident."),
          code(S["float"], "float.tern"),
          img(d1, "After tapping Raise price once", w=2.9 * inch),
          *table(["To go from", "Write"],
                 [["Int to Float", "`toFloat(qty)`"],
                  ["Float to Int", "`round(x)`   `floor(x)`   `ceil(x)`"],
                  ["Float to Text, tidy", "`fixed(x, 2)`, which gives `\"7.50\"`"],
                  ["Float to Text, as is", "`toText(x)`, which gives `\"7.5\"`"],
                  ["typed Text to Float", "`toFloatOr(text, 0.0)`, which uses the fallback if the text is not a number"],
                  ["typed Text to Int", "`toIntOr(text, 0)`"]], [2.0, 4.7]),
          P("Division with two `Float` values is exact (`7.0 / 2.0` is `3.5`). Division with two `Int` values still rounds "
            "down. `%` works only on `Int`."),
          code(BAD["e_mix"][0], "Mixing Int and Float"),
          img(em_path, f"Tern says: {em_err.msg}", w=2.9 * inch),
          H2("Example: a tip calculator"),
          code(S["tipcalc"], "tipcalc.tern"),
          img(d2, "After typing 80 and tapping 20%", w=2.9 * inch),
          P("The text box gives `Text`, so `toFloatOr` turns it into a number, and if someone types nonsense the "
            "calculator shows zero instead of breaking."),
          CondPageBreak(3.6 * inch)]

# ---- 17 structs
sb1, _ = shot("struct_basic_after", [("click", "Birthday")], key="struct_basic")
sc1, _ = shot("struct_cart_after", [("click", "More tea")], key="struct_cart")
es_path, es_err = err_shot("e_struct")
_, ep_err = err_shot("e_struct_pos")
lv_path, lv_err = err_shot("e_loopvar")
_, sr_err = err_shot("e_selfret")
story += [CondPageBreak(4 * inch), H1("17. Structs: your own types"),
          P("So far each fact lived in its own state. A shop that needs names, prices and quantities would need three "
            "lists that you must keep in step. A `struct` groups the facts about one thing into a single value with a "
            "name of its own, and can carry the small functions that work on it, called **methods**."),
          code(S["struct_basic"], "struct_basic.tern"),
          img(sb1, "After tapping Birthday once", w=2.9 * inch),
          *table(["To", "Write"],
                 [["declare a struct (at the top, outside `view`)", "`struct Person { name: Text  age: Int }`, one field per line"],
                  ["make one", "`Person(name: \"Ada\", age: 36)`. Every field, by name"],
                  ["read a field", "`me.name`   `cart[0].price`"],
                  ["change a field", "`me.age = 37`   `cart[0].qty = cart[0].qty + 1`"],
                  ["make a changed copy", "`me with age: 37`, or several: `me with name: \"Grace\", age: 40`"],
                  ["use it as a type", "`state me: Person`, `fn birthday(p: Person): Person`, `List<Person>`"]], [2.4, 4.3]),
          H2("Methods"),
          P("A `fn` inside a struct is a method. It reaches the struct it was called on through `self`. Call it with a dot: "
            "`me.greeting()`."),
          bullets(["A method that **returns a value**, like `greeting()`, only reads `self`.",
                   "A method that **returns nothing**, like `birthday()`, may change `self`. Call it as its own statement, "
                   "such as a button's action, on a variable or on a list item: `me.birthday()`, `cart[0].more()`.",
                   "A method sees only `self` and its own arguments, so a struct in a library works the same as one in a page."]),
          H2("Structs are values"),
          P("A struct is a value, like a number. `let b = a` makes a copy, and changing `b` never changes `a`. Under the "
            "hood a change such as `me.birthday()` builds a new `Person` and stores it back in `me`. That keeps every "
            "change visible in your page's state and makes surprises impossible: two names can never secretly "
            "share one struct."),
          P("The same idea explains the one rule that trips people up. A loop variable is a copy of a list item, so a method "
            "that changes it would be lost. Tern refuses, and tells you to change the list instead."),
          code(BAD["e_loopvar"][0], "Changing a copy"),
          img(lv_path, f"Tern says: {lv_err.msg}", w=2.9 * inch),
          H2("Lists of structs"),
          P("Structs shine in lists: one list, and every row is a whole item. `cart[0].more()` reaches into the list, changes "
            "that one item, and stores the list back."),
          code(S["struct_cart"], "struct_cart.tern"),
          img(sc1, "After tapping More tea", w=2.9 * inch),
          H2("Named fields keep you safe"),
          P("You must give every field, by name, so a missing or misspelled field is caught before the page runs. "
            "Giving values by position, as in `Item(\"Tea\", 3)`, is not allowed."),
          code(BAD["e_struct"][0], "A missing field"),
          img(es_path, f"Tern says: {es_err.msg}", w=2.9 * inch),
          P("Position-only values get a clear message too: **" + str(ep_err) + "**"),
          callout("Note", "**Rules of structs.** Two different structs are different types, even with the same fields. "
                          "`==` compares two values of the same struct field by field. A struct can hold other structs and "
                          "lists, but never itself. Field names cannot be reserved words, so `size` and `color` are out "
                          "(try `boxSize`). A method that returns a value cannot change `self`: "
                          "Tern says **" + sr_err.msg + "**. `toText` does not take a struct; use it on a field, as in `toText(me.age)`. "
                          "To change one item of a list you may write `cart[0].qty = 3`, but a whole item is still replaced "
                          "with `setAt`."),
          CondPageBreak(3.6 * inch)]

# ---- 18 libraries
lp1, _ = shot("lib_page_after", [("click", "Add tea")], key="lib_page")
lt = app_shot("libs_tab", S["lib_page"], "libs", height=720)
le_path, le_err = err_shot("e_lib")
lf_path, lf_err = err_shot("e_libfile")
story += [CondPageBreak(4 * inch), H1("18. Libraries: sharing logic"),
          P("As pages grow, the rules (how a total is worked out, how money is shown) get mixed up with the layout, "
            "and a second page needs the same rules again. A **library** is a separate file that holds only "
            "the rules. It ends in `.ternlib`."),
          code(LIB_SHOP, "shop.ternlib"),
          P("A page uses it with `use`, near the top. Everything that comes from the library is written with the "
            "library's name in front, so it can never clash with your own names."),
          code(S["lib_page"], "shop.tern"),
          img_row([(lp1, "The page, after Add tea"), (lt, "The Libraries tab")], w=2.3),
          *table(["Write", "To"],
                 [["`use \"shop.ternlib\"`", "load the library file `shop.ternlib`"],
                  ["`shop.total(cart)`", "call the library's function `total`"],
                  ["`shop.Item`", "use its struct as a type, as in `List<shop.Item>`"],
                  ["`shop.Item(name: \"Tea\", price: 3, qty: 1)`", "make one of its structs"]], [2.9, 3.8]),
          H2("Where the library lives"),
          bullets(["**In the playground**, open the **Libraries** tab, type a name such as `shop`, tap **Add library** and "
                   "write the code. **Use in page** adds the `use` line for you. Libraries stay on this device.",
                   "**In Tern Browser**, put `shop.ternlib` in the same folder as the page. A page can only name a file "
                   "that sits beside it: no folders, no addresses."]),
          H2("What a library may hold"),
          P("Only `struct` and `fn`. That is the point: a library can work things out, but it cannot draw anything, keep "
            "`state`, change pages with `goto`, or load other libraries. A library cannot read the page's state either; "
            "give the function what it needs as arguments. Because of this, a library from someone else can "
            "never change what your page does behind your back. Structs in a library can have methods too."),
          P("A second page can reuse exactly the same rules:"),
          code(S["lib_second"], "receipt.tern"),
          H2("Errors"),
          P("A page that asks for something the library does not have is caught before it runs, and Tern lists what the "
            "library does have."),
          code(BAD["e_lib"][0], "A misspelled library function"),
          img(le_path, f"Tern says: {le_err.msg}", w=2.9 * inch),
          P("A mistake inside the library is reported with the library's file name and its own line numbers. The error "
            "card shows the library's code."),
          img(lf_path, f"Tern says: {lf_err}", w=2.9 * inch),
          *callout("Note", "**Good to know.** Library names are letters, digits and `_`, followed by `.ternlib`, and cannot be "
                         "a reserved word. Do not use a library's name for a state, function, parameter or variable. "
                         "Libraries cannot yet use other libraries, and pages opened from a web address cannot load "
                         "libraries yet."),
          CondPageBreak(3.6 * inch)]

# ---- 19 errors
story += [CondPageBreak(4 * inch), H1("19. Reading error messages"),
          P("Tern reports three kinds of problem. Every message gives a line and column, and the Page tab "
            "also shows the line of code. Read the message literally; it usually tells you the fix."),
          H2("Type errors: caught before the page runs")]
for k, title, expl in [
    ("e_types", "Mixing Text and Int", "Convert with `toText(age)`."),
    ("e_name", "A typo in a name", "`cuont` is not defined. Check spelling."),
    ("e_ret", "A function that forgets to return", "If `n` is not greater than 0, nothing is returned."),
]:
    path, e = err_shot(k)
    story += flat([code(BAD[k][0], title + "  (" + k + ".tern)"),
                            img(path, f"Tern says: {e.msg}", w=2.9 * inch), P(expl)])
story += [H2("Syntax errors: the file is not valid Tern")]
path, e = err_shot("e_syntax")
story += [KeepTogether(flat([code(BAD["e_syntax"][0], "A missing closing brace"),
                        P("Tern says: **" + str(e) + "**")]))]
story += [H2("Runtime errors: the page works until one specific action goes wrong")]
rt = runtime_msg("e_div", "Divide")
story += [KeepTogether(flat([code(RUNTIME["e_div"], "Dividing by zero"),
                        P("Clicking Divide shows this above the page: **" + str(rt) + "**"),
                        P("The page keeps working, and only that action is cancelled. Runtime errors come from "
                          "dividing by zero, indexing outside a list, and recursing too deeply.")])),
          CondPageBreak(3.6 * inch)]

# ---- 10 quiz
def quiz_row():
    cells = []
    for key, acts, caption in [
        ("quiz_a", [], "Start"),
        ("quiz_b", [("type", "guess", "4"), ("click", "Submit"), ("type", "guess", "Paris")], "Mid-game"),
        ("quiz_c", [("type", "guess", "4"), ("click", "Submit"), ("type", "guess", "paris"),
                    ("click", "Submit"), ("type", "guess", "no"), ("click", "Submit")], "The end")]:
        path, _ = shot(key, acts, key="quiz", width=330)
        iw, ih = PILImage.open(path).size
        w = 2.1 * inch
        cells.append([Image(path, width=w, height=w * ih / iw), Paragraph(caption, cap)])
    t = Table([[c for c in cells]], colWidths=[2.2 * inch] * 3)
    t.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP")]))
    t = Table([[cells[0], cells[1], cells[2]]], colWidths=[2.25 * inch] * 3)
    t.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP")]))
    return KeepTogether([t])


story += [H1("20. Project: a quiz"),
          P("Time to combine everything. This page asks questions one at a time, checks answers, keeps score, "
            "and offers a replay. It uses state, two functions, `input`, `button`, `if`/`else` in the view, "
            "lists, indexing, and text built from pieces."),
          code(S["quiz"], "quiz.tern"),
          H2("How it works"),
          bullets(["`index` says which question we are on. `questions[index]` fetches its text.",
                   "While `index < len(questions)` the view shows the question, a box and a Submit button. "
                   "Once we run out, the `else` branch shows the final score.",
                   "`submit()` compares the guess to the answer. `lower` and `trim` ignore capital letters "
                   "and stray spaces. Then it clears the box and moves on.",
                   "`feedback` holds the message after each answer, and the view just displays it."]),
          quiz_row(),
          H2("Ideas to extend it"),
          bullets(["Add more questions, remembering to add an answer for each.",
                   "Show the running score while playing.",
                   "Add a `link` to a second quiz page on another topic."]),
          H2("What Tern 0.3 does not have (yet)"),
          P("User-defined record types, saving data between visits, animation, and pages that fetch data "
            "from the network. Pages cannot read files or reach the internet, which keeps them safe to open, "
            "but it also means this is a learning language, not yet a replacement for a full web stack."),
          CondPageBreak(3.6 * inch)]

# ---- 11 exercises
story += [PageBreak(), H1("21. Exercises"),
          P("Try each one before reading the solutions on the next pages. The status line under your code "
            "tells you straight away whether the page type-checks."),
          H2("1. Full name"),
          P("Make a page with two text boxes, first name and last name, that shows the full name underneath. "
            "(Hint: two `Text` states and `+`.)"),
          H2("2. A counter with a floor"),
          P("Take the counter from chapter 4 and make the minus button stop at zero."),
          H2("3. Clear all"),
          P("Make a page that lists three items and has a button that removes them all at once."),
          H2("4. FizzBuzz"),
          P("Show the numbers 1 to 15, one per line. Print `Fizz` instead of multiples of 3, `Buzz` instead of "
            "multiples of 5, and `FizzBuzz` for multiples of both. (Hint: write a function "
            "`fizz(n: Int): Text`, and use `%`.)"),
          H2("5. A profile card"),
          P("Make a card: a column with a light blue background and some padding, holding a heading, a gray italic "
            "job title, and a paragraph in which one phrase is bold. (Hint: a named style for the card.)"),
          H2("6. Expenses"),
          P("Show three expenses in a table with a final Total row. Add the numbers up in a function."),
          H2("7. A two-page site"),
          P("Make a home page with a heading and a button that opens a contact page. The contact page shows an email "
            "address and a Back button. Give both buttons a named style."),
          H2("8. Split the bill"),
          P("A text box takes the bill. Plus and minus buttons change the number of people (never below one). "
            "Show what each person pays with two decimals. (Hint: `toFloatOr`, `toFloat`, `fixed`.)"),
          H2("9. Break it on purpose"),
          P("Take any working page and introduce one mistake: a wrong type, a misspelled name, a missing "
            "`return`. Predict the error message before you type it in."),
          CondPageBreak(3.6 * inch)]

# ---- solutions
story += [PageBreak(), H1("Solutions")]
sol_notes = {"ex1": "1. Full name", "ex2": "2. A counter with a floor",
             "ex3": "3. Clear all", "ex4": "4. FizzBuzz", "ex5": "5. A profile card", "ex6": "6. Expenses",
             "ex7": "7. A two-page site", "ex8": "8. Split the bill"}
expl = {"ex1": "`trim` tidies the result when one of the boxes is empty.",
        "ex2": "The `if` inside `down()` only subtracts when the count is above zero.",
        "ex3": "`[]` is allowed here because Tern already knows `items` is a `List<Text>`.",
        "ex4": "Check the multiples of 15 first, otherwise 15 would print just `Fizz`.",
        "ex5": "`column style card` applies the style's background and padding. The `span` in bold stands out inside the paragraph.",
        "ex6": "`cells` can sit after the `for`. The last row adds the Total by calling `total()`.",
        "ex7": "The first view is the start page. `goto contact` moves forward and `back` returns.",
        "ex8": "`people` is an `Int` and the bill is a `Float`, so `toFloat(people)` converts before dividing. `fewer()` keeps the count at one or more."}
for k in ["ex1", "ex2", "ex3", "ex4", "ex5", "ex6", "ex7", "ex8"]:
    story += [H2(sol_notes[k]), code(S[k]), P(expl[k])]
story += [CondPageBreak(3.6 * inch)]

# ---- appendix
story += [PageBreak(), H1("Appendix A: Quick reference"),
          H2("Reserved words"),
          P("`page  state  fn  view  let  if  else  for  foreach  in  return  true  false  to  placeholder  "
            "text  heading  button  input  row  column  link  divider  style  size  color  background  align  "
            "padding  bold  italic  underline  strike  when  para  span  table  header  cells  bullet  image  alt  width  "
            "height  radius  border  font  goto  back  struct  with  use  self  checkbox  resizable  modal  gap  margin  grow  maxwidth  minwidth  grid  select  radio  textarea  slider  disabled  saved  every`. "
            "You cannot use these as names. Type names (`Int`, `Text`, `Bool`, `List`) start with a capital letter. The built-in colour and alignment names (`black white gray red green blue orange purple yellow pink`, `left center right`, `sans serif mono display hand rounded`) can be used but not changed."),
          H2("Built-in functions"),
          *table(["Function", "Type", "What it does"],
                 [["`toText(x)`", "Int, Bool or Text -> Text", "Convert to text"],
                  ["`len(x)`", "Text or List -> Int", "Length"],
                  ["`append(xs, x)`", "List<T>, T -> List<T>", "New list with x on the end"],
                  ["`removeAt(xs, i)`", "List<T>, Int -> List<T>", "New list without item i"],
                  ["`range(n)`", "Int -> List<Int>", "0 up to n-1 (at most 10000)"],
                  ["`slice(xs, a, b)`", "List<T>, Int, Int -> List<T>", "Items a up to b-1; out-of-range is trimmed"],
                  ["`sort(xs)`", "List<Int|Float|Text> -> same", "New list, smallest first"],
                  ["`sortOrder(xs)`", "List<Int|Float|Text> -> List<Int>", "Positions in sorted order"],
                  ["`reverse(xs)`", "List<T> -> List<T>", "New list, back to front"],
                  ["`trim(s)`", "Text -> Text", "Remove spaces at both ends"],
                  ["`upper(s)` / `lower(s)`", "Text -> Text", "Change case"],
                  ["`contains(s, part)`", "Text, Text -> Bool", "Is part inside s?"],
                  ["`join(xs, sep)`", "List<Text>, Text -> Text", "Glue items together"],
                  ["`setAt(xs, i, x)`", "List<T>, Int, T -> List<T>", "New list with item i replaced"],
                  ["`rgb(r, g, b)`", "Int, Int, Int -> Color", "A colour; each part 0 to 255"],
                  ["`toFloat(n)`", "Int -> Float", "Whole number to decimal"],
                  ["`round(x)` `floor(x)` `ceil(x)`", "Float -> Int", "Nearest, down, up"],
                  ["`fixed(x, places)`", "Float, Int -> Text", "Text with a set number of decimals"],
                  ["`sqrt(x)`", "Float -> Float", "Square root"],
                  ["`toIntOr(s, fallback)`", "Text, Int -> Int", "Typed text to a number, or the fallback"],
                  ["`toFloatOr(s, fallback)`", "Text, Float -> Float", "Typed text to a decimal, or the fallback"]], [1.8, 2.5, 2.4]),
          H2("Structs and libraries"),
          *table(["Write", "Meaning"],
                 [["`struct Item { name: Text  price: Int }`", "declare a struct, one field per line"],
                  ["`Item(name: \"Tea\", price: 3)`", "make one: every field, by name"],
                  ["`item.name`", "read a field"],
                  ["`item.price = 4`", "change a field (on a variable or a list item of one)"],
                  ["`item with price: 4`", "a changed copy; several fields with commas"],
                  ["`fn more() { self.qty = self.qty + 1 }`", "a method inside a struct; no return value, so it may change `self`"],
                  ["`item.more()`   `cart[0].more()`", "call a method with a dot"],
                  ["`use \"shop.ternlib\"`", "load a library (`struct` and `fn` only)"],
                  ["`shop.total(xs)`   `shop.Item`", "a library's function or struct, always with its name in front"]], [3.0, 3.7]),
          H2("Style properties"),
          *table(["Property", "Value", "Works on"],
                 [["`size 20`", "Int, points (6 to 96)", "text, heading, bullet, para, span, link, button"],
                  ["`bold` `italic` `strike`", "optional `when Bool`", "text, heading, bullet, para, span, link, button"],
                  ["`underline`", "optional `when Bool`", "text, heading, bullet, para, span"],
                  ["`color red`", "Color", "text, heading, bullet, para, span, link, button"],
                  ["`background #fff3bf`", "Color", "text, heading, bullet, para, span, button, row, column"],
                  ["`font serif`", "Font", "text, heading, bullet, para, span, link, button"],
                  ["`align center`", "Align", "text, heading, bullet, para; image"],
                  ["`padding 12`", "Int, pixels (0 to 64)", "text, heading, bullet, para, button, row, column"],
                  ["`radius 10`", "Int, pixels (0 to 999)", "text, heading, bullet, para, button, row, column, image"],
                  ["`border gray`", "Color", "text, heading, bullet, para, button, row, column, image"],
                  ["`width 200`", "Int, pixels", "button, row, column, image"],
                  ["`height 100`", "Int, pixels", "image"],
                  ["`alt \"text\"`", "Text", "image"],
                  ["`style a b`", "named styles, in order", "anything above (unused properties are ignored)"]],
                 [1.7, 1.9, 3.1]),
          H2("Operator order (tightest first)"),
          P("function call and `xs[i]`, then unary `!` and `-`, then `* / %`, then `+ -`, then "
            "`< > <= >=`, then `== !=`, then `&&`, then `||`. Use parentheses when in doubt."),
          H2("Appendix B: Common mistakes"),
          *table(["You wrote", "Fix"],
                 [["`text \"Total: \" + total`", "`text \"Total: \" + toText(total)`"],
                  ["`if count { ... }`", "`if count > 0 { ... }`"],
                  ["`items = append(items, x)` missing, only `append(items, x)`",
                   "Lists never change in place. Assign the result back."],
                  ["`state xs: List<Int> = []` written as `let xs = []`",
                   "Give it a type: `let xs: List<Int> = []`"],
                  ["`input count` where `count` is an `Int`", "Inputs only edit `Text` state"],
                  ["`button \"Go\" -> 1 + 2`", "A button needs a call or an assignment"],
                  ["`return` in a button", "Only functions can return; call a function instead"],
                  ["`text \"x\" color \"red\"`", "Colours are not text. Write `color red`, with no quotes"],
                  ["`cells \"Tea\"` under a two-column header", "Every row needs the same number of cells"],
                  ["`para { text \"x\" }`", "Inside a paragraph, write `span \"x\"`"],
                  ["`toText(n * 1.5)` where `n` is an `Int`", "Int and Float never mix. Use `toFloat(n) * 1.5`"],
                  ["`button \"Go\" -> goto shop` with no `view shop`", "Declare the page: `view shop { ... }`"],
                  ["`image \"lgo\"`", "Image names must match one in the Images tab"],
                  ["`Item(\"Tea\", 3)`", "Give every field by name: `Item(name: \"Tea\", price: 3)`"],
                  ["`for i in cart { i.more() }`", "`i` is a copy, so the change is lost. Write `cart[0].more()`"],
                  ["a method that returns a value and sets `self.x`", "Split it: one method changes, another returns"],
                  ["`struct Box { size: Int }`", "`size` is a reserved word; try `boxSize`"],
                  ["`total(cart)` for a library function", "Write the library name first: `shop.total(cart)`"]], [3.0, 3.7])]

doc.multiBuild(flat(story))
print("built", os.path.join(OUT, "Learn_Tern.pdf"))
