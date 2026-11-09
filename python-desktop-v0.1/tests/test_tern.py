import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from tern import TernError, load, render_text  # noqa: E402
from tern.browser import resolve, fetch, error_lines  # noqa: E402

EX = os.path.join(os.path.dirname(__file__), "..", "examples")


def page(body, decls=""):
    return load(f'page "t"\n{decls}\nview {{\n{body}\n}}')


def bad(src):
    with unittest.TestCase().assertRaises(TernError) as cm:
        load(src)
    return cm.exception


def click(p, label):
    for n in p.render():
        if n["t"] == "button" and n["label"] == label:
            return n["click"]()
        for c in n.get("children", []):
            if c["t"] == "button" and c["label"] == label:
                return c["click"]()
    raise AssertionError(f"no button {label}")


class TypeErrors(unittest.TestCase):
    def check_err(self, src, phase, needle):
        e = bad(src)
        self.assertEqual(e.phase, phase)
        self.assertIn(needle, e.msg)
        return e

    def test_text_plus_int(self):
        e = self.check_err('state n: Int = 1\nview { text "a" + n }', "type error", "toText")
        self.assertEqual(e.pos[0], 2)

    def test_wrong_state_init(self):
        self.check_err('state n: Int = "x"\nview { }', "type error", "needs Int")

    def test_assign_wrong_type(self):
        self.check_err('state n: Int = 1\nview { button "b" -> n = "no" }', "type error", "needs Int")

    def test_unknown_name(self):
        self.check_err('view { text missing }', "type error", "unknown name")

    def test_if_needs_bool(self):
        self.check_err('view { if 1 { text "x" } }', "type error", "needs Bool")

    def test_missing_return(self):
        self.check_err('fn f(): Int { }\nview { }', "type error", "must return Int")

    def test_return_wrong_type(self):
        self.check_err('fn f(): Int { return "s" }\nview { }', "type error", "needs Int")

    def test_arg_count_and_type(self):
        self.check_err('fn f(a: Int) { }\nview { button "b" -> f() }', "type error", "takes 1")
        self.check_err('fn f(a: Int) { }\nview { button "b" -> f("x") }', "type error", "needs Int")

    def test_empty_list_needs_type(self):
        self.check_err('view { for x in [] { text "a" } }', "type error", "empty list")

    def test_mixed_list(self):
        self.check_err('state xs: List<Int> = [1, "a"]\nview { }', "type error", "needs Int")

    def test_input_needs_text_state(self):
        self.check_err('state n: Int = 0\nview { input n }', "type error", "Text state")

    def test_compare_different_types(self):
        self.check_err('view { if 1 == "a" { text "x" } }', "type error", "cannot compare")

    def test_syntax_errors(self):
        self.check_err('view { text "unterminated }', "syntax error", "unterminated")
        self.check_err('view { text }', "syntax error", "expression")
        self.check_err('state x: Float = 1\nview { }', "syntax error", "unknown type")
        self.check_err('text "a"', "syntax error", "expected")

    def test_no_view(self):
        self.check_err('page "x"', "syntax error", "no view")

    def test_expression_statement(self):
        self.check_err('view { button "b" -> 1 + 2 }', "type error", "does nothing")


class Runtime(unittest.TestCase):
    def test_counter_clicks(self):
        p = load(open(os.path.join(EX, "counter.tern")).read())
        text = lambda: "\n".join(render_text(p.render()))
        self.assertIn("Count: 0", text())
        click(p, "+")
        click(p, "+")
        self.assertIn("Count: 2", text())
        self.assertIn("Even.", text())
        click(p, "Step 5")
        click(p, "-")
        self.assertIn("Count: -3", text())
        self.assertIn("Below zero.", text())
        click(p, "Reset")
        self.assertIn("Count: 0", text())

    def test_todo_add_and_remove(self):
        p = load(open(os.path.join(EX, "todo.tern")).read())
        row = next(n for n in p.render() if n["t"] == "row")
        inp = next(n for n in row["children"] if n["t"] == "input")
        inp["set"]("  buy milk ")
        click(p, "Add")
        out = "\n".join(render_text(p.render()))
        self.assertIn("3. buy milk", out)
        self.assertIn("3 item(s)", out)
        self.assertEqual(p.state["draft"], "")
        for _ in range(3):
            click(p, "Done")
        self.assertIn("All done!", "\n".join(render_text(p.render())))

    def test_greeting_binding(self):
        p = load(open(os.path.join(EX, "home.tern")).read())
        self.assertIn("Type your name", "\n".join(render_text(p.render())))
        next(n for n in p.render() if n["t"] == "input")["set"]("Sam")
        self.assertIn("Hello, Sam!", "\n".join(render_text(p.render())))

    def test_functions_recursion_and_scopes(self):
        p = page('text toText(fact(5))\ntext toText(total)', '''
state total: Int = 0
fn fact(n: Int): Int { if n <= 1 { return 1 } return n * fact(n - 1) }
''')
        self.assertEqual(p.render()[0]["text"], "120")

    def test_for_let_and_closures_capture_loop_var(self):
        p = page('for i in range(3) { button toText(i) -> total = total + i * 10 }\ntext toText(total)',
                 'state total: Int = 0')
        click(p, "2")
        click(p, "1")
        self.assertEqual(p.render()[-1]["text"], "30")

    def test_runtime_errors_are_tern_errors(self):
        p = page('button "go" -> n = 1 / zero\ntext toText(n)',
                 'state n: Int = 0\nstate zero: Int = 0')
        with self.assertRaises(TernError) as cm:
            click(p, "go")
        self.assertEqual(cm.exception.phase, "runtime error")
        self.assertIn("division by zero", cm.exception.msg)
        p = page('button "go" -> n = xs[5]', 'state n: Int = 0\nstate xs: List<Int> = [1]')
        with self.assertRaises(TernError):
            click(p, "go")

    def test_deep_recursion_is_reported_not_crashed(self):
        p = page('button "go" -> n = f(1)', 'state n: Int = 0\nfn f(x: Int): Int { return f(x + 1) }')
        with self.assertRaises(TernError):
            click(p, "go")

    def test_integer_division_and_modulo(self):
        p = page('text toText(7 / 2) + " " + toText(7 % 2) + " " + toText(-3 + 1)')
        self.assertEqual(p.render()[0]["text"], "3 1 -2")

    def test_string_escapes_and_builtins(self):
        p = page('text upper("a\\tb") + join(["x", "y"], ",") + toText(contains("hello", "ell"))')
        self.assertEqual(p.render()[0]["text"], "A\tBx,ytrue")

    def test_else_if_chain(self):
        p = page('if n == 1 { text "one" } else if n == 2 { text "two" } else { text "many" }',
                 'state n: Int = 2')
        self.assertEqual(p.render()[0]["text"], "two")


class BrowserLogic(unittest.TestCase):
    def test_resolve(self):
        self.assertEqual(resolve("examples/home.tern", "todo.tern"), os.path.normpath("examples/todo.tern"))
        self.assertEqual(resolve("http://a.com/x/y.tern", "z.tern"), "http://a.com/x/z.tern")
        self.assertEqual(resolve("a/b.tern", "http://c.com/d.tern"), "http://c.com/d.tern")
        self.assertEqual(resolve("/a/b.tern", "../c.tern"), os.path.normpath("/c.tern"))

    def test_fetch_file_and_missing(self):
        with tempfile.NamedTemporaryFile("w", suffix=".tern", delete=False) as f:
            f.write('view { text "hi" }')
        self.assertEqual(fetch(f.name), 'view { text "hi" }')
        self.assertEqual(fetch("file://" + f.name), 'view { text "hi" }')
        os.unlink(f.name)
        with self.assertRaises(OSError):
            fetch(f.name)

    def test_error_report_shows_source_line(self):
        src = open(os.path.join(EX, "broken.tern")).read()
        try:
            load(src)
        except TernError as e:
            lines = error_lines(e, src)
            self.assertEqual(lines[0], "Type Error")
            self.assertIn('text "Count: " + count', lines[-1])
        else:
            self.fail("expected error")

    def test_all_examples_but_broken_load(self):
        for name in os.listdir(EX):
            if name == "broken.tern":
                continue
            load(open(os.path.join(EX, name)).read()).render()


if __name__ == "__main__":
    unittest.main()
