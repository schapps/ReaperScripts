-- @description Sonic Affirmations
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   A simple lua script to show the user a positive affirmation each time it is run.
-- @link https://www.stephenschappler.com
-- @changelog 
--   02/13/25 v1.0 - Creating the script

local affirmations = {
    "I am capable of creating amazing soundscapes!",
    "I trust my ears—my instincts are valuable.",
    "Sound design is an art—there are no wrong choices, just creative ones!",
    "I am a creative force, shaping immersive soundscapes.",
    "I turn silence into a canvas for sonic art.",
    "My sound design elevates every project I touch.",
    "I trust my instincts to create captivating audio.",
    "Each beat I produce fuels innovative game experiences.",
    "I am the architect of dynamic and emotive sound.",
    "My creativity transforms ideas into vibrant soundscapes.",
    "I embrace experimentation to discover new auditory horizons.",
    "I am proud to design sounds that resonate deeply.",
    "My audio creations add life to virtual worlds.",
    "I find inspiration in every whisper, echo, and tone.",
    "I sculpt sound with passion and precision.",
    "Every challenge in sound design is an opportunity to grow.",
    "I am a pioneer in crafting immersive audio experiences.",
    "I create sonic magic that ignites the imagination.",
    "My work bridges technology and artistic expression.",
    "I breathe emotion into every sound I design.",
    "I trust the creative process that guides my work.",
    "I am dedicated to shaping unforgettable auditory journeys.",
    "My soundscapes tell stories that captivate and inspire.",
    "I design audio that transforms gameplay into an art form.",
    "I innovate with every click, tweak, and wave.",
    "My creative energy flows through every project.",
    "I celebrate my unique vision as a sound designer.",
    "I find beauty in the details of every sonic element.",
    "My work is a testament to the power of creativity.",
    "I am confident in my ability to create game-changing sounds.",
    "I transform ordinary moments into extraordinary audio experiences.",
    "I am in tune with the rhythm of my creative spirit.",
    "Every sound I create adds depth to the gaming experience.",
    "I embrace each new project as a fresh sonic adventure.",
    "I sculpt audio landscapes that evoke emotion and wonder.",
    "My creativity is limitless and ever-evolving.",
    "I design sound that moves hearts and minds.",
    "I am fearless in exploring uncharted sonic territories.",
    "My work resonates with passion, purpose, and power.",
    "I use sound to breathe life into digital worlds.",
    "I trust my inner muse to guide my audio creations.",
    "I celebrate the art of sound in every project.",
    "I am constantly pushing the boundaries of audio design.",
    "My creativity transforms challenges into breakthrough ideas.",
    "I create soundscapes that inspire and captivate audiences.",
    "I am a master of crafting vibrant and immersive audio.",
    "Every tone I design is a step toward innovation.",
    "I trust in my ability to bring ideas to life through sound.",
    "I am grateful for the power of sound to tell compelling stories.",
    "I weave creativity and technology into every sound I create.",
    "My sound design is the heartbeat of immersive experiences.",
    "I celebrate my role as a creative visionary in the world of sound."
}

local function show_random_message()
    if #affirmations == 0 then
        reaper.MB("No affirmations available!", "Error", 0)
        return
    end

    -- Pick a random affirmation
    math.randomseed(os.time() + reaper.time_precise()) -- Improved randomness
    local random_index = math.random(#affirmations)
    local message = affirmations[random_index]

    -- Display it
    reaper.MB(message, "Sonic Affirmations", 0)
end

-- Execute the function
show_random_message()
