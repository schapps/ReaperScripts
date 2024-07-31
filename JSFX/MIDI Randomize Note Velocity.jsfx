/**
 * JSFX Name: MIDI Randomize Note Velocity
 * About: Randomize MIDI Note Velocity
 * Author: Stephen Schappler
 * Author URI: http://www.stephenschappler.com
 * Version: 1.0
 */

/**
 * Changelog:
 * v1.0 Initial Release 07-30-2024
 */

  desc:Randomize MIDI note velocity
  //tag: midi
  slider1:1<0,1,1{Off,On}>Randomize
  
  @init
  // MIDI message types
  NOTE_ON = 0x90;
  
  @block
  while (midirecv(offset, msg1, msg2, msg3))
  (
      // Check if it's a Note On message with non-zero velocity and if randomization is enabled
      slider1 == 1 && (msg1 & 0xF0) == NOTE_ON && msg3 != 0 ? (
          // Generate a random velocity between 1 and 127
          msg3 = rand(127) + 1;
      );
  
      // Send the MIDI message
      midisend(offset, msg1, msg2, msg3);
  )
  
  