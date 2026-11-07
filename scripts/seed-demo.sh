#!/bin/bash
# Creates a demo Buoy database in the folder you give it, for screenshots and testing.
# It never touches your real data:
#
#   scripts/seed-demo.sh /tmp/buoy-demo
#   BUOY_DATA_DIR=/tmp/buoy-demo .build/debug/Buoy
#
# Dates are relative to today. Needs a debug build (swift build).
set -euo pipefail
DIR="${1:?usage: scripts/seed-demo.sh <folder>}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
case "$DIR" in
  *"Application Support/Buoy"*) echo "Refusing to write into a real Buoy data folder." >&2; exit 1 ;;
esac
rm -rf "$DIR"; mkdir -p "$DIR"
# Let the app create and migrate an empty database (snapshot mode quits on its own).
BUOY_DATA_DIR="$DIR" BUOY_SNAPSHOT_DIR="$DIR/.warm" "$REPO/.build/debug/Buoy" >/dev/null 2>&1 || true
rm -rf "$DIR/.warm"
DB="$DIR/Buoy.sqlite"
NOW=$(date +%s)
d() { date -v"${1}"d +%Y-%m-%d; }          # d +3 → date 3 days from today
ago() { echo $((NOW - $1 * 86400)); }      # ago 23 → epoch 23 days ago
u() { uuidgen; }
T_ERR=$(u); T_FIN=$(u); T_HOME=$(u); T_TRAVEL=$(u); T_WORK=$(u)
R_RENT=$(u); R_WATER=$(u); R_HVAC=$(u)
CAR=$(u); DENT=$(u); RENT=$(u); WATER=$(u); INK=$(u); FLIGHTS=$(u); REVIEW=$(u); DRY=$(u)
OFFSITE=$(u); DESK=$(u); PASS=$(u); HVAC=$(u); GARDEN=$(u); EXP=$(u); GYM=$(u)
L_BREAD=$(u); L_SHELF=$(u); L_BIKE=$(u)
P_KITCHEN=$(u); P_TEAM=$(u); P_BEDS=$(u); P_SWIFT=$(u); P_PHOTOS=$(u); P_REFI=$(u)
P_ROADMAP=$(u); P_GARAGE=$(u); P_LAPTOP=$(u); P_KIDS=$(u); P_SITE=$(u)
SNOOZE_UNTIL=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(d +2) 00:00:00" +%s)
sqlite3 "$DB" <<SQL
PRAGMA foreign_keys = ON;
INSERT INTO tags VALUES ('$T_ERR','Errands',$NOW),('$T_FIN','Finance',$NOW),('$T_HOME','Home',$NOW),('$T_TRAVEL','Travel',$NOW),('$T_WORK','Work',$NOW);
INSERT INTO recurrence_rules (id, unit, interval, mode, anchor_on, created_at) VALUES
  ('$R_RENT','month',1,'schedule','$(d +3)',$NOW),
  ('$R_WATER','day',3,'schedule','$(d +0)',$NOW),
  ('$R_HVAC','day',90,'completion',NULL,$NOW);
INSERT INTO tasks (id,title,notes,show_on,due_on,lead_days,snoozed_until,surfaced_at,recurrence_rule_id,created_at,updated_at) VALUES
  ('$CAR','Renew car registration','Bring the inspection slip.',NULL,'$(d -2)',0,NULL,NULL,NULL,$(ago 6),$(ago 6)),
  ('$DENT','Call the dentist','',NULL,'$(d +0)',0,NULL,NULL,NULL,$(ago 3),$(ago 3)),
  ('$RENT','Pay rent','Pay through the portal at rent.example.com/pay',NULL,'$(d +3)',5,NULL,NULL,'$R_RENT',$(ago 10),$(ago 10)),
  ('$WATER','Water the plants','','$(d +0)',NULL,0,NULL,NULL,'$R_WATER',$(ago 2),$(ago 2)),
  ('$INK','Order printer ink','',NULL,NULL,0,NULL,NULL,NULL,$(ago 23),$(ago 23)),
  ('$FLIGHTS','Book flights for the holidays','','$(d +0)',NULL,0,NULL,NULL,NULL,$(ago 1),$(ago 1)),
  ('$REVIEW','Draft the quarterly review','','$(d +1)',NULL,0,NULL,NULL,NULL,$(ago 4),$(ago 4)),
  ('$DRY','Pick up dry cleaning','','$(d +1)',NULL,0,NULL,NULL,NULL,$(ago 1),$(ago 1)),
  ('$OFFSITE','Prepare for the team offsite','',NULL,NULL,0,$SNOOZE_UNTIL,NULL,NULL,$(ago 5),$(ago 5)),
  ('$DESK','Research standing desks','','$(d +7)',NULL,0,NULL,NULL,NULL,$(ago 2),$(ago 2)),
  ('$PASS','Renew passport','',NULL,'2026-12-01',30,NULL,NULL,NULL,$(ago 9),$(ago 9)),
  ('$HVAC','Replace HVAC filter','','2026-11-20',NULL,0,NULL,NULL,'$R_HVAC',$(ago 30),$(ago 30)),
  ('$GARDEN','Plan the spring garden','','2027-03-01',NULL,0,NULL,NULL,NULL,$(ago 12),$(ago 12)),
  ('$EXP','Submit expense report','',NULL,'$(d +0)',0,NULL,NULL,NULL,$(ago 3),$(ago 3)),
  ('$GYM','Cancel the old gym membership','',NULL,NULL,0,NULL,NULL,NULL,$(ago 8),$(ago 8));
-- Parked in Later.
INSERT INTO tasks (id,title,notes,due_on,lead_days,created_at,updated_at,later) VALUES
  ('$L_BREAD','Learn to make sourdough','',NULL,0,$(ago 3),$(ago 3),1),
  ('$L_SHELF','Reorganize the bookshelf','',NULL,0,$(ago 6),$(ago 6),1),
  ('$L_BIKE','Tune up the bike before spring','','2027-03-15',7,$(ago 14),$(ago 14),1);
INSERT INTO tasks (id,title,notes,due_on,lead_days,created_at,updated_at,kind,board_column,board_position,source,status,result,expectations) VALUES
  ('$P_KITCHEN','Kitchen remodel','Get three quotes.',NULL,0,$(ago 20),$(ago 20),'project','shaping',1,'user','','',''),
  ('$P_TEAM','Plan the team offsite','','$(d +12)',7,$(ago 9),$(ago 9),'project','shaping',2,'user','','',''),
  ('$P_BEDS','Redo the garden beds','',NULL,0,$(ago 30),$(ago 30),'project','shaping',3,'user','','',''),
  ('$P_KIDS','Passports for the kids','Waiting on photos.','2026-12-15',30,$(ago 12),$(ago 12),'project','shaping',4,'user','','',''),
  ('$P_PHOTOS','Digitize old photos','',NULL,0,$(ago 50),$(ago 50),'project','shaping',5,'agent','','',''),
  ('$P_REFI','Compare mortgage refinance offers','Our rate is 6.1%. Look at the three banks we already use; I want a one-page comparison.','2026-11-30',14,$(ago 60),$(ago 60),'project','ready',1,'user','','','One page: each offer''s rate, fees and break-even month in a table, then your recommendation in two sentences. Save it to Documents/Finance.'),
  ('$P_SWIFT','Summarize Swift concurrency changes','For the team wiki. Notes at swift.org/documentation',NULL,0,$(ago 40),$(ago 40),'project','ready',2,'user','','',''),
  ('$P_ROADMAP','Draft the Q4 roadmap','Leadership reviews it on the 3rd. Last quarter''s roadmap is in the same folder; keep the same four sections. Mobile is out of scope this time.','$(d +5)',3,$(ago 7),$(ago 7),'project','in_progress',1,'user','Drafting section 2 of 4','','A draft in the shared doc, two pages at most, with one line per initiative: the goal, the owner and the rough size. End with three open questions for me. I will judge it on whether I could present it as is.'),
  ('$P_LAPTOP','Research laptop options for Sam','Budget around \$1,500; mostly photo editing.',NULL,0,$(ago 10),$(ago 10),'project','in_progress',2,'user','Comparing three models','',''),
  ('$P_GARAGE','Find a garage organizer','',NULL,0,$(ago 15),$(ago 1),'project','in_progress',3,'user','','',''),
  ('$P_SITE','Launch the family website','',NULL,0,$(ago 30),$(ago 1),'project','in_progress',0,'user','','Published the site and sent everyone the link. Photos from the reunion are on the Gallery page.','');
INSERT INTO task_tags VALUES ('$CAR','$T_ERR'),('$RENT','$T_FIN'),('$RENT','$T_HOME'),('$WATER','$T_HOME'),('$INK','$T_ERR'),
  ('$FLIGHTS','$T_TRAVEL'),('$REVIEW','$T_WORK'),('$OFFSITE','$T_WORK'),('$PASS','$T_FIN'),('$HVAC','$T_HOME'),('$EXP','$T_WORK'),
  ('$L_SHELF','$T_HOME'),
  ('$P_KITCHEN','$T_HOME'),('$P_GARAGE','$T_HOME'),('$P_ROADMAP','$T_WORK'),('$P_TEAM','$T_WORK'),('$P_REFI','$T_FIN');
INSERT INTO completions VALUES ('$(u)','$EXP',$((NOW - 3600)),NULL),('$(u)','$GYM',$(ago 1),NULL),('$(u)','$P_SITE',$(ago 2),NULL);
INSERT INTO notes (id,text,created_at,updated_at,archived_at) VALUES
  ('$(u)','Retro ideas #work
- keep it to 30 minutes
- start with what went well
- ask Dana about the release checklist',$((NOW-600)),$((NOW-600)),NULL),
  ('$(u)','Book recommendation from Sam: The Overstory',$((NOW-7800)),$((NOW-7800)),NULL),
  ('$(u)','Wifi at the cabin: LakeHouse-5G / pinecone42',$((NOW-90000)),$((NOW-90000)),NULL),
  ('$(u)','Gift ideas for mom
- the tea shop on 5th
- a photo book',$((NOW-400000)),$((NOW-400000)),$((NOW-200000)));
-- Your agent's estimates, and one project handed in for review.
UPDATE tasks SET effort_hours = 3 WHERE id = '$P_REFI';
UPDATE tasks SET effort_hours = 1.5 WHERE id = '$P_SWIFT';
UPDATE tasks SET effort_hours = 6 WHERE id = '$P_ROADMAP';
UPDATE tasks SET effort_hours = 0.5 WHERE id IN ('$DENT', '$INK');
UPDATE tasks SET effort_hours = 2 WHERE id = '$FLIGHTS';
UPDATE tasks SET effort_hours = 2, board_column = 'review', board_position = 0, status = '',
  result = 'Compared the MacBook Air 15, MacBook Pro 14 and Dell XPS 15 in a table in Documents/Sam laptop.numbers. I''d pick the Air: it fits the budget and handles Lightroom fine.'
  WHERE id = '$P_LAPTOP';
PRAGMA wal_checkpoint(TRUNCATE);
SQL
echo "Demo data in $DIR: $(sqlite3 "$DB" "SELECT count(*) FROM tasks WHERE kind='task'") tasks ($(sqlite3 "$DB" "SELECT count(*) FROM tasks WHERE later=1") in Later), $(sqlite3 "$DB" "SELECT count(*) FROM tasks WHERE kind='project'") projects, $(sqlite3 "$DB" 'SELECT count(*) FROM notes') notes."
