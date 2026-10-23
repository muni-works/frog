#!/bin/sh
# makes boot copies of index.html for screenshots: .snap/<screen>-<theme>.html
cd "$(dirname "$0")" && ./build.sh && mkdir -p .snap
for s in activity inbox transcript dead pod agent menubar; do for t in dark light; do
  sed "s|<body class=\"dark\">|<body class=\"dark\"><script>window.BOOT=\"$s,$t,still\"</script>|" index.html > .snap/$s-$t.html
done; done
