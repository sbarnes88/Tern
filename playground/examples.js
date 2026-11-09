/* Example pages for the playground and the tests. */
(function (root) {
const EXAMPLES = [
{ id: 'welcome', name: 'Welcome', src: `page "Welcome to Tern"

// A page = state (what it remembers), fn (what it can do), view (what it shows)
state name: Text = ""

fn greeting(who: Text): Text {
  if trim(who) == "" {
    return "Type your name above."
  }
  return "Hello, " + trim(who) + "!"
}

view {
  heading "Welcome to Tern" color blue
  text "A small, strongly typed language for web pages."
  divider
  input name placeholder "Your name"
  text greeting(name) bold
}
` },

{ id: 'counter', name: 'Counter', src: `page "Counter"

state count: Int = 0
state step: Int = 1

fn bump(by: Int) {
  count = count + by
}

fn describe(n: Int): Text {
  if n == 0 { return "Nothing yet." }
  if n < 0 { return "Below zero." }
  if n % 2 == 0 { return "Even." }
  return "Odd."
}

view {
  heading "Counter"
  text "Count: " + toText(count) size 28 bold
  text describe(count) italic color gray
  row {
    button "-" -> bump(0 - step)
    button "+" -> bump(step)
    button "Reset" -> count = 0
  }
  text "Step size: " + toText(step)
  row {
    button "Step 1" -> step = 1
    button "Step 5" -> step = 5
    button "Step 10" -> step = 10
  }
}
` },

{ id: 'todo', name: 'Todo list', src: `page "Todo list"

state items: List<Text> = ["Try Tern", "Break something on purpose"]
state draft: Text = ""

fn add() {
  if trim(draft) != "" {
    items = append(items, trim(draft))
    draft = ""
  }
}

view {
  heading "Todo list"
  row {
    input draft placeholder "What needs doing?"
    button "Add" -> add()
  }
  if len(items) == 0 {
    text "All done!" color green bold
  } else {
    text toText(len(items)) + " item(s)" color gray
  }
  for i in range(len(items)) {
    row {
      text toText(i + 1) + ". " + items[i]
      button "Done" -> items = removeAt(items, i)
    }
  }
}
` },

{ id: 'styles', name: 'Style gallery', src: `page "Style gallery"

// Named styles: define once, use anywhere
style title { size 28 bold color blue }
style note { italic color gray size 11 }
style warning { bold color red background #fdecea }

state pts: Int = 16

view {
  heading "Style gallery" color purple
  text "Big, bold and blue" style title
  text "A quiet note in gray italics." style note
  text "Careful: this is a warning." style warning
  divider
  para {
    span "You can mix "
    span "bold" bold
    span ", "
    span "italic" italic
    span ", "
    span "underlined" underline
    span ", "
    span "struck" strike
    span " and "
    span "coloured" color orange bold
    span " words in one sentence."
  }
  divider
  text "Resize me" size pts
  row {
    button "A-" -> pts = pts - 2
    button "A+" -> pts = pts + 2
  }
  text "Size is " + toText(pts) + " points" style note
  text "Centered" align center color rgb(130, 80, 223)
  text "Right aligned" align right
}
` },

{ id: 'table', name: 'Price table', src: `page "Order"

state names: List<Text> = ["Tea", "Coffee", "Cake"]
state prices: List<Int> = [3, 4, 5]
state qty: List<Int> = [2, 1, 3]

fn money(n: Int): Text {
  return "$" + toText(n)
}

fn total(): Int {
  let sum = 0
  for i in range(len(names)) {
    sum = sum + prices[i] * qty[i]
  }
  return sum
}

view {
  heading "Your order"
  table {
    header "Item", "Price", "Qty", "Subtotal"
    for i in range(len(names)) {
      cells names[i], money(prices[i]), toText(qty[i]), money(prices[i] * qty[i])
    }
  }
  text "Total: " + money(total()) size 20 bold
  row {
    for i in range(len(names)) {
      button "+ " + names[i] -> qty = setAt(qty, i, qty[i] + 1)
    }
  }
}
` },

{ id: 'article', name: 'Article page', src: `page "Tern in five minutes"

style lead { size 15 color gray italic }
style callout { background #eef3fc padding 12 }

view {
  heading "Tern in five minutes"
  text "A short guide to a very small language." style lead
  divider
  para {
    span "Tern pages are made of "
    span "state" bold
    span ", "
    span "functions" bold
    span " and a "
    span "view" bold
    span ". Everything is type-checked before it runs."
  }
  heading "What you get" size 18
  bullet "Text in any size, bold, italic, underline or strike"
  bullet "Colours by name, by hex like #0b57d0, or rgb(r, g, b)"
  bullet "Tables, lists and layout rows"
  bullet "Named styles you write once and reuse"
  heading "Quick comparison" size 18
  table {
    header "Type", "Example", "Holds"
    cells "Int", "42", "whole numbers"
    cells "Text", "\\"hi\\"", "words"
    cells "Bool", "true", "yes or no"
    cells "Color", "#0b57d0", "a colour"
  }
  column style callout {
    text "Tip" bold color blue
    text "Mistakes are reported with a line number before the page runs."
  }
}
` },

{ id: 'pages', name: 'Multi-page site', src: `page "Corner Cafe"

style chip { background #eef3fc color blue radius 20 padding 8 border #c5d3f0 }
style cta { background blue color white bold radius 10 padding 12 }

state orders: Int = 0
state names: List<Text> = ["Espresso", "Flat white", "Croissant"]
state prices: List<Float> = [2.5, 3.2, 4.0]

// Each "view name" is a page. Buttons and links move between them.
view home {
  image "mountains" width 320 radius 12 alt "Mountains at dawn"
  heading "Corner Cafe" font display size 28
  text "Small coffee shop. Slow mornings." font serif italic color gray
  row {
    button "Menu" style chip -> goto menu
    button "About" style chip -> goto about
  }
  button "Order a coffee" style cta -> orders = orders + 1
  text toText(orders) + " ordered today" color gray
}

view menu {
  heading "Menu" font display
  table {
    header "Item", "Price"
    for i in range(len(names)) {
      cells names[i], "$" + fixed(prices[i], 2)
    }
  }
  button "Back" -> back
}

view about {
  heading "About us" font display
  para {
    span "We opened in "
    span "2019" bold
    span " and we are open every day."
  }
  row {
    link "Home" -> goto home
    link "Our website" to "https://example.com"
  }
}
` },

{ id: 'tip', name: 'Tip calculator', src: `page "Tip calculator"

state bill: Text = ""
state percent: Int = 15

// Int and Float are different types. toFloat() converts, and
// toFloatOr() turns typed text into a number (or uses the fallback).
fn amount(): Float {
  return toFloatOr(bill, 0.0)
}

fn tip(): Float {
  return amount() * toFloat(percent) / 100.0
}

view {
  heading "Tip calculator"
  input bill placeholder "Bill amount, e.g. 42.50"
  row {
    button "10%" bold when percent == 10 -> percent = 10
    button "15%" bold when percent == 15 -> percent = 15
    button "20%" bold when percent == 20 -> percent = 20
  }
  text "Tip (" + toText(percent) + "%): $" + fixed(tip(), 2)
  text "Total: $" + fixed(amount() + tip(), 2) size 22 bold
}
` },

{ id: 'fonts', name: 'Fonts', src: `page "Fonts"

state pick: Font = serif

view {
  heading "Fonts" font display
  text "sans: The quick brown fox" font sans
  text "serif: The quick brown fox" font serif
  text "mono: The quick brown fox" font mono
  text "display: The quick brown fox" font display size 18
  text "hand: The quick brown fox" font hand size 20
  text "rounded: The quick brown fox" font rounded
  divider
  text "Pick a font below" font pick size 22
  row {
    button "serif" -> pick = serif
    button "hand" -> pick = hand
    button "mono" -> pick = mono
  }
}
` },

{ id: 'images', name: 'Images', src: `page "Images"

view {
  heading "Images"
  image "mountains" width 300 radius 12 alt "Mountains at dawn"
  text "Rounded corners, 300 wide." color gray size 11
  row {
    image "avatar" width 64 height 64 radius 999 alt "A friendly face"
    column {
      text "Sam Rivera" bold
      text "Photographer" italic color gray
    }
  }
  image "sunset" width 300 border gray alt "Sunset over water"
  image "logo" width 120 align center alt "Tern logo"
  text "Add your own photos in the Images tab." italic color gray
}
` },

{ id: 'buttons', name: 'Styled buttons', src: `page "Buttons"

style primary { background blue color white bold radius 10 padding 12 }
style ghost { color blue border blue radius 10 padding 10 background white }
style danger { background red color white radius 6 padding 10 }
style pill { background #e8f5e9 color green radius 999 padding 8 bold }

state clicks: Int = 0
state on: Bool = false

view {
  heading "Styled buttons"
  button "Primary" style primary -> clicks = clicks + 1
  button "Ghost" style ghost -> clicks = clicks + 1
  button "Danger (resets)" style danger -> clicks = 0
  button "Pill +5" style pill -> clicks = clicks + 5
  button "Wide button" style primary width 280 -> clicks = clicks + 1
  button "Serif italic" font serif italic size 16 -> clicks = clicks + 1
  button "Toggle" style ghost bold when on -> on = !on
  text "Clicks: " + toText(clicks) size 20 bold
  text "Toggle is " + toText(on) color gray
}
` },

{ id: 'quiz', name: 'Quiz', src: `page "Quiz"

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
    text "Question " + toText(index + 1) + ": " + questions[index] size 16 bold
    input guess placeholder "Your answer"
    button "Submit" -> submit()
  } else {
    text "Finished! Score: " + toText(score) + " out of " + toText(len(questions)) size 20 bold color green
    button "Play again" -> restart()
  }
  text feedback italic
}
` },

{ id: 'datatable', name: 'Data table (sort, pages, pick)', src: `page "Desserts"

// A data table: sortable columns (sortOrder), pages of four rows (slice),
// and a checkbox in the first column to pick rows.
struct Dessert {
  name: Text
  calories: Int
  fat: Int
}

state rows: List<Dessert> = [
  Dessert(name: "Cupcake", calories: 305, fat: 4),
  Dessert(name: "Donut", calories: 452, fat: 25),
  Dessert(name: "Eclair", calories: 262, fat: 16),
  Dessert(name: "Froyo", calories: 159, fat: 6),
  Dessert(name: "Gingerbread", calories: 356, fat: 16),
  Dessert(name: "Honeycomb", calories: 408, fat: 3),
  Dessert(name: "Ice cream", calories: 237, fat: 9),
  Dessert(name: "Jelly bean", calories: 375, fat: 0),
  Dessert(name: "KitKat", calories: 518, fat: 26)
]
state picked: List<Bool> = [false, false, false, false, false, false, false, false, false]
state sortBy: Text = "none"
state ascending: Bool = true
state pageNo: Int = 0

// the positions of the rows, in the order they should be shown
fn order(): List<Int> {
  if sortBy == "none" { return range(len(rows)) }
  let keys: List<Int> = []
  for d in rows {
    if sortBy == "calories" { keys = append(keys, d.calories) } else { keys = append(keys, d.fat) }
  }
  if ascending { return sortOrder(keys) }
  return reverse(sortOrder(keys))
}

// tapping a column sorts by it; tapping the same column again flips the direction
fn sortOn(which: Text) {
  if sortBy == which { ascending = !ascending } else { sortBy = which ascending = true }
  pageNo = 0
}

fn arrow(which: Text): Text {
  if sortBy != which { return "" }
  if ascending { return " ▲" }
  return " ▼"
}

fn lastShown(): Int {
  let last = pageNo * 4 + 4
  if last > len(rows) { return len(rows) }
  return last
}

fn pageCount(): Int { return (len(rows) + 3) / 4 }

fn pickedCount(): Int {
  let n = 0
  for p in picked { if p { n = n + 1 } }
  return n
}

view {
  heading "Desserts"
  text "Tap Calories or Fat to sort; tap again to flip the direction. Tick rows to pick them." color gray
  table height 260 padding 9 border #1f3a5f resizable {
    header "Pick" background #1f3a5f color white, "Dessert" background #1f3a5f color white, button "Calories" + arrow("calories") background #1f3a5f color white radius 0 border #1f3a5f -> sortOn("calories"), button "Fat" + arrow("fat") background #1f3a5f color white radius 0 border #1f3a5f -> sortOn("fat")
    for i in slice(order(), pageNo * 4, pageNo * 4 + 4) {
      cells checkbox picked[i] -> picked = setAt(picked, i, !picked[i]), rows[i].name bold when picked[i], toText(rows[i].calories), toText(rows[i].fat)
    }
    cells "Picked: " + toText(pickedCount()) span 4 background #dbe7fb color #1f3a5f bold
  }
  row {
    if pageNo > 0 {
      button "Previous" background #0b57d0 color white radius 20 padding 12 bold -> pageNo = pageNo - 1
    }
    text "Page " + toText(pageNo + 1) + " of " + toText(pageCount())
    if pageNo < pageCount() - 1 {
      button "Next" background #0b57d0 color white radius 20 padding 12 bold -> pageNo = pageNo + 1
    }
    button "Unsort" color #b3261e border #b3261e radius 20 padding 12 -> { sortBy = "none" ascending = true pageNo = 0 }
  }
  text "Rows " + toText(pageNo * 4 + 1) + " to " + toText(lastShown()) + " of " + toText(len(rows)) size 11 color gray
}
` },

{ id: 'editable', name: 'Editable list (text boxes in a table)', src: `page "Editable list"

// Text boxes can edit one item of a list, or a field of a struct in a list,
// including inside a table.
struct Person {
  name: Text
  city: Text
}

state people: List<Person> = [
  Person(name: "Ada", city: "London"),
  Person(name: "Grace", city: "New York"),
  Person(name: "Linus", city: "Helsinki")
]

view {
  heading "People"
  text "Edit any cell. The change is stored in the list." color gray
  table padding 6 {
    header "Name", "City"
    for i in range(len(people)) {
      cells input people[i].name placeholder "Name", input people[i].city placeholder "City"
    }
  }
  button "Add a person" -> people = append(people, Person(name: "", city: ""))
  divider
  for p in people {
    text p.name + " lives in " + p.city
  }
}
` },

{ id: 'modal', name: 'Dialogs (modal)', src: `page "Dialogs"

// A modal is drawn over the page while its Bool is true. Tap the dim area or press Escape to close it.
state items: List<Text> = ["Tea", "Cake", "Bread"]
state askAt: Int = -1          // which item we are asking about; -1 means none
state about: Bool = false

view {
  heading "Shopping list"
  for i in range(len(items)) {
    row {
      text items[i]
      button "Remove" -> askAt = i
    }
  }
  button "About" -> about = true

  // an expression modal says how it closes
  modal askAt >= 0 width 320 radius 16 -> askAt = -1 {
    heading "Remove this item?"
    text items[askAt] bold
    row {
      button "Cancel" -> askAt = -1
      button "Remove" background #b3261e color white -> { items = removeAt(items, askAt) askAt = -1 }
    }
  }

  // a modal on a plain Bool state closes by setting it to false
  modal about padding 24 {
    heading "About"
    text "Dialogs sit on top of the page, which is dimmed and cannot be tapped behind them."
    button "Close" -> about = false
  }
}
` },

{ id: 'layout', name: 'Layout (gap, grid, grow)', src: `page "Layout"

// gap, margin, align, grow, maxwidth and grid
style card { background #f6f8fa padding 14 radius 10 border #d0d7de }

state cards: Int = 6

view {
  heading "Layout"

  // align spread pushes the items to opposite ends
  row align spread padding 12 background #1f3a5f radius 8 {
    text "Tern Shop" bold color white size 16
    row gap 18 {
      text "Home" color white
      text "Cart" color white
    }
  }

  // grow gives each block a share of the row: here 1 part and 3 parts
  row gap 12 {
    column grow 1 style card {
      text "Side" bold
      text "1 part" color gray
    }
    column grow 3 style card {
      text "Main" bold
      text "3 parts" color gray
    }
  }

  // a grid lays its children out in equal columns
  row {
    button "Fewer" -> { if cards > 1 { cards = cards - 1 } }
    button "More" -> { if cards < 12 { cards = cards + 1 } }
  }
  grid 3 gap 10 {
    for i in range(cards) {
      column style card gap 2 {
        text "Card " + toText(i + 1) bold
        text "in a grid" color gray size 10
      }
    }
  }

  // align center centers the children INSIDE a column. To put the card itself in the middle of
  // the page, wrap it in another column that has align center. maxwidth keeps the card narrow.
  column align center {
    column align center gap 6 maxwidth 360 style card {
      heading "Centered" size 16
      text "A narrow card in the middle of the page." color gray
      button "OK" -> cards = 6
    }
  }
}
` },

{ id: 'form', name: 'Form (dropdown, radio)', src: `page "Sign up"

// select is a dropdown, radio shows every choice. Both store the choice in a Text state
// (or a place inside one, like members[i].role).
struct Member {
  name: Text
  role: Text
}

state name: Text = ""
state country: Text = ""
state plan: Text = "Free"
state agree: Bool = false
state done: Bool = false
state countries: List<Text> = ["France", "Japan", "Peru"]
state roles: List<Text> = ["admin", "editor", "viewer"]
state members: List<Member> = [
  Member(name: "Ada", role: "admin"),
  Member(name: "Linus", role: "")
]

fn ready(): Bool {
  return trim(name) != "" && country != "" && agree
}

view {
  heading "Sign up"
  input name placeholder "Your name"
  select country in countries placeholder "Country"
  text "Plan" bold
  radio plan in ["Free", "Pro", "Team"]
  checkbox agree "I agree to the terms"
  button "Create account" -> if ready() { done = true }
  if !ready() {
    text "Enter a name, pick a country and agree to continue." color gray size 10
  }

  divider
  heading "Team" size 16
  table padding 8 {
    header "Member", "Role"
    for i in range(len(members)) {
      cells members[i].name, select members[i].role in roles placeholder "Pick a role"
    }
  }

  modal done {
    heading "Welcome"
    text name + " from " + country + ", on the " + plan + " plan."
    button "Done" -> done = false
  }
}
` },

{ id: 'feedback', name: 'Feedback (textarea, slider, disabled)', src: `page "Feedback"

// textarea is a multi-line text box, slider picks a number in a range,
// and disabled greys a control out (it can depend on state with when).
state notes: Text = ""
state rating: Int = 3
state agree: Bool = false
state sent: Bool = false

fn ready(): Bool {
  return len(trim(notes)) >= 10 && agree
}

view {
  heading "Feedback"
  text "Tell us what you think (at least 10 characters)."
  textarea notes placeholder "Your feedback" height 110 width 320
  text toText(len(notes)) + " characters" size 10 color gray

  text "Rating: " + toText(rating) + " / 5" bold
  slider rating in 1 to 5 width 220

  checkbox agree "You may quote me"
  button "Send" disabled when !ready() -> sent = true
  if !ready() {
    text "Send turns on once the feedback is long enough and you agree." size 10 color gray
  }

  modal sent {
    heading "Thank you"
    text "You rated us " + toText(rating) + " out of 5."
    button "Close" -> sent = false
  }
}
` },

{ id: 'stopwatch', name: 'Stopwatch (every, saved)', src: `page "Stopwatch"

// every runs an action on a timer while its condition holds (here: while running).
// A saved state is kept between visits, so the laps are still here when you come back.
state running: Bool = false
state tenths: Int = 0
saved state laps: List<Int> = []

fn show(t: Int): Text {
  return toText(t / 10) + "." + toText(t % 10) + " s"
}

view {
  heading "Stopwatch"
  text show(tenths) size 36 bold
  every 100 when running -> tenths = tenths + 1

  row {
    if running {
      button "Pause" -> running = false
    } else {
      button "Start" -> running = true
    }
    button "Lap" -> laps = append(laps, tenths)
    button "Reset" -> { running = false tenths = 0 }
  }

  heading "Laps" size 16
  if len(laps) == 0 {
    text "No laps yet." color gray
  }
  for i in range(len(laps)) {
    bullet toText(i + 1) + ".  " + show(laps[i])
  }
  button "Clear laps" -> laps = []
}
` },

{ id: 'structs', name: 'Structs (shopping cart)', src: `page "Cart"

// A struct groups typed fields. Its methods work on self.
struct Item {
  name: Text
  price: Int
  qty: Int

  fn lineTotal(): Int {
    return self.price * self.qty
  }

  // a method that returns nothing may change self
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
` },

{ id: 'library', name: 'Library (shop)', libs: { shop: `// shop.ternlib: shared logic, no drawing, no state.
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
` }, src: `page "Shop with a library"

// The rules live in shop.ternlib (see the Libraries tab).
// Everything from the library is written with "shop." in front.
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
` },

{ id: 'foreach', name: 'Foreach loop', src: `page "Foreach loop"

state fruits: List<Text> = ["Apple", "Banana", "Cherry", "Date"]
state picked: Text = "none"

view {
  heading "Foreach loop"
  text "A grid keeps the names and buttons in aligned columns (no table)."
  grid 2 gap 8 {
    foreach fruit in fruits {
      text fruit
      button "Pick" -> picked = fruit
    }
  }
  divider
  text "Picked: " + picked bold
}
` },

{ id: 'broken', name: 'Broken on purpose', src: `page "Broken on purpose"

state count: Int = 0

view {
  heading "Type errors are caught before the page runs"
  text "Count: " + count
}
` },
];
const api = { EXAMPLES };
if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.TernExamples = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
