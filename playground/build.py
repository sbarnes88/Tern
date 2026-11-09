src = open("playground.src.html").read()
out = src.replace("/*TERN_JS*/", open("tern.js").read()).replace("/*EXAMPLES_JS*/", open("examples.js").read())
open("index.html", "w").write(out)
print("built", len(out))
