// keep the token and preferences saved under the project's old name
try {
  for (const k of Object.keys(localStorage)) {
    if (k.startsWith('recbridge.') && localStorage.getItem('bdzbridge.' + k.slice(10)) === null) localStorage.setItem('bdzbridge.' + k.slice(10), localStorage.getItem(k))
  }
} catch { /* storage unavailable */ }
import { mount } from 'svelte'
import './app.css'
import App from './App.svelte'

export default mount(App, { target: document.getElementById('app') })
