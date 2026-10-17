-- What the game client does to the colours a frame asks for, measured from an
-- in-game screenshot of the light window (macOS, Retina, October 2026): every
-- channel of every pixel comes out as gain * c + offset, clipped to 1. Fills,
-- text, item icons and the world behind the window all follow it, so it is a
-- screen-wide brightness and contrast, not something the colour calls do; the
-- fit over 21 samples is within 2.5/255 on average, 9.6/255 at most.
local Client = { gain = 1.204, offset = 0.101 }

function Client.Render(value)
  return math.min(1, math.max(0, Client.gain * value + Client.offset))
end

return Client
