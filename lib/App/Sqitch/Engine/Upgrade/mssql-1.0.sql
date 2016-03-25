ALTER TABLE sqitch.changes ADD script_hash VARCHAR(40) NULL;
UPDATE sqitch.changes SET script_hash = change_id;