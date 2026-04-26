package dev.ibiza.tweaktrak.wrapper

import android.os.Bundle
import androidx.activity.enableEdgeToEdge

class MainActivity : TauriActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    registerPlugin(MidiPlugin::class.java)
    enableEdgeToEdge()
    super.onCreate(savedInstanceState)
  }
}
