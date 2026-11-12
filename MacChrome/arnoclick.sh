#!/bin/bash
# ARNOCLICK (Chrome): apre la pagina di ARNOCLICK in una finestra di Google Chrome senza barra degli indirizzi.
URL="https://maarnone52-oss.github.io/ArnoClick/"
if open -Ra "Google Chrome" >/dev/null 2>&1; then
  open -na "Google Chrome" --args --app="$URL" --window-size=1280,800
else
  osascript -e 'display dialog "ARNOCLICK ha bisogno di Google Chrome.\n\nOra si apre la pagina per scaricarlo: installalo, poi riapri ARNOCLICK." buttons {"OK"} default button 1 with title "ARNOCLICK" with icon caution' >/dev/null 2>&1
  open "https://www.google.com/chrome/"
fi
