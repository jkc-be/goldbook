-- Gold was kept per day, as [[day, copper], ...]. It is now kept per hour by
-- unix time, as [[time, copper], ...]. A day's balance becomes that of its last
-- hour, and today's that of the current hour, as in the addon's own upgrade.
-- Times a newer sync agent already sent stay as they are: a day number is far
-- below any of them.
UPDATE characters
SET gold = (
  SELECT json_group_array(json_array(
    CASE
      WHEN value ->> 0 < 1000000000 THEN MIN(((value ->> 0) * 24 + 23) * 3600, unixepoch() / 3600 * 3600)
      ELSE value ->> 0
    END,
    value ->> 1
  ))
  FROM json_each(characters.gold)
);
