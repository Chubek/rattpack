# Chapter 10: HTML and LaTeX Templates

EZDox uses the `inja2` template engine to render HTML and LaTeX output. Templates
are stored in `templates/html` and `templates/latex` and are copied to the output
directory during generation.

## Template Directory Layout

```
templates/
  html/
    index.html
    navigate.html
    manifest.html
    csslib/
      bootstrap.min.css
      highlight.min.css
      animate.min.css
      pico.min.css
    jslib/
      highlight.min.js
      mathjax.js
      lucide.esm.js
      graph.full.min.js
      alpine.js
      jquery.min.js
  latex/
    header.ltx
    footer.ltx
    ezdox.cls
```

## HTML Templates

The main HTML template is `index.html`. It uses `inja` syntax:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <title>{{ project }}</title>
  <link rel="stylesheet" href="csslib/bootstrap.min.css">
</head>
<body>
  <nav class="sidebar">
    <h2>{{ project }} {{ version }}</h2>
    <ul>
      {% for item in items %}
      <li><a href="#{{ item.symbol }}">{{ item.symbol }}</a></li>
      {% endfor %}
    </ul>
  </nav>
  <main class="main">
    <h1>{{ project }}</h1>
    {% for item in items %}
    <section id="{{ item.symbol }}">
      <h3>{{ item.symbol }}</h3>
      <p>{{ item.brief }}</p>
      {% if item.params %}
      <table>
        {% for key, value in item.params %}
        <tr><td>{{ key }}</td><td>{{ value }}</td></tr>
        {% endfor %}
      </table>
      {% endif %}
    </section>
    {% endfor %}
  </main>
</body>
</html>
```

## Meta-Variables

Templates can use the following meta-variables:

| Variable | Description |
|----------|-------------|
| `project` | Project name from config |
| `version` | Project version from config |
| `sources` | List of source directories |
| `items` | List of `DocItem` objects |
| `item.symbol` | Entity name |
| `item.brief` | Brief description |
| `item.details` | Detailed description |
| `item.params` | Parameter map |
| `item.returns` | Return description |
| `item.references` | Cross-reference list |

## LaTeX Templates

LaTeX output is assembled from three parts:

1. `header.ltx` — Preamble, title, and table of contents.
2. Body — Generated from the document model.
3. `footer.ltx` — Closing `\end{document}`.

The `ezdox.cls` class file defines colors, fonts, and listing styles. You can
customize it by copying the template directory and editing the `.cls` file.

## Custom Templates

To use a custom template directory:

```bash
ezdox-cli generate -C EZDox.yaml -O build/docs -t HTML --template my-templates/
```

EZDox looks for `index.html` under `my-templates/html/` and `header.ltx` under
`my-templates/latex/`.

## Template Debugging

If a template fails to render, EZDox prints the `inja` error message including
the line number. Common issues:

- Missing closing `{% endfor %}`
- Using `{{ item.param }}` instead of `{{ item.params }}`
- Forgetting to escape special characters in LaTeX templates

## Best Practices

- Keep templates under version control.
- Use `{% if %}` guards to handle optional fields gracefully.
- Test templates with a small project before applying them to large codebases.
