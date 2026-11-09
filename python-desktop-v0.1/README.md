# Tern

A tiny browser and a strongly typed page language. No HTML, no JavaScript, no TypeScript.
Pure Python 3.9+ (the window uses the built-in `tkinter`).

```
python -m tern browse                      # opens examples/home.tern
python -m tern browse examples/todo.tern   # or any file / http(s) URL
python -m tern check examples/broken.tern  # type-check only
python -m tern text examples/counter.tern  # print as plain text
python -m tern png examples/todo.tern out.png   # headless screenshot (needs Pillow)
python -m unittest discover -s tests
```

## The language

```
page "Counter"

state count: Int = 0              // state is typed and global to the page

fn bump(by: Int) {                // functions are typed too
  count = count + by
}

view {                            // the page: re-evaluated after every change
  heading "Counter"
  text "Count: " + toText(count)  // no implicit conversion: Text + Int is an error
  row {
    button "-" -> bump(0 - 1)
    button "+" -> bump(1)
  }
  input name placeholder "Name"   // two-way binds to a Text state
  if count > 3 { text "Big!" } else { text "Small" }
  for i in range(3) { text toText(i) }
  link "Home" to "home.tern"
  divider
}
```

Types: `Int`, `Text`, `Bool`, `List<T>`. Everything is checked before the page runs;
errors show in the browser with line, column and the offending source line.

Built-ins: `toText len append removeAt range trim upper lower contains join`.
Operators: `+ - * / %` (Int division), `== != < > <= >=`, `&& || !`.

## Layout

- `tern/lang.py`    lexer, parser, type checker, runtime, text renderer
- `tern/browser.py` Tk window, history, links, error pages (`resolve` and `fetch` are GUI-free)
- `tern/png.py`     headless renderer
- `examples/`       home, counter, todo, broken (deliberate type error)

## Not done yet

Styling, images, forms beyond text input, a Float type, user-defined record types,
network requests from pages, and a real security sandbox (pages can't touch files or the
network at all, which is the point, but it hasn't been audited).
