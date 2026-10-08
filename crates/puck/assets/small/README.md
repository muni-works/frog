Latin-only subsets of the faces one level up, for the device (`--features small-fonts`).
fontdue keeps every glyph's outline in memory, and the full faces need 9.5 MB once loaded.

Regenerate with fonttools:

    U="U+0020-007E,U+00A0-017F,U+2010-2027,U+2030-203A,U+20AC,U+2190-2193,U+2713,U+2715,U+2717"
    for f in Nunito-Regular Nunito-Bold JetBrainsMono-Medium; do
      pyftsubset ../$f.ttf --unicodes="$U" --layout-features='' --no-hinting --desubroutinize \
        --output-file=$f.ttf
    done
