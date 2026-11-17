import React from 'react'
import ReactDOM from 'react-dom/client'
import Satellites from './satellites.jsx'
import './style.css'

// Satellites – Frontend-Einstiegspunkt
ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <Satellites />
  </React.StrictMode>
)