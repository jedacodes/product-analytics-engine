import csv
import random
from datetime import datetime, timedelta

NUM_USERS = 1000
MAX_EVENTS_PER_USER = 25

events_pool = [
    'sign_up', 'profile_setup', 'view_catalog', 
    'use_search_filter', 'add_to_cart', 'invite_friend', 'complete_purchase'
]

platforms = ['iOS', 'Android', 'Web']

start_date = datetime(2026, 9, 1)

rows = []
event_id_counter = 100000

for user_id_num in range(1, NUM_USERS + 1):
    user_id = f"USR_{user_id_num:04d}"
    platform = random.choice(platforms)
    
    # Random signup date within first 30 days
    current_time = start_date + timedelta(days=random.randint(0, 30), seconds=random.randint(0, 86400))
    
    # User always starts with sign_up
    rows.append([f"EVT_{event_id_counter}", user_id, 'sign_up', current_time.strftime('%Y-%m-%d %H:%M:%S'), platform])
    event_id_counter += 1
    
    # Generate subsequent events with realistic time gaps
    num_events = random.randint(2, MAX_EVENTS_PER_USER)
    for _ in range(num_events):
        # 70% chance gap is under 30 mins (same session), 30% chance gap is larger (new session)
        if random.random() < 0.7:
            gap_seconds = random.randint(30, 1500)
        else:
            gap_seconds = random.randint(3600, 86400 * 5)
            
        current_time += timedelta(seconds=gap_seconds)
        
        # Don't extend past simulation window
        if current_time > start_date + timedelta(days=60):
            break
            
        chosen_event = random.choices(
            events_pool[1:], 
            weights=[0.25, 0.25, 0.20, 0.15, 0.05, 0.10], 
            k=1
        )[0]
        
        rows.append([f"EVT_{event_id_counter}", user_id, chosen_event, current_time.strftime('%Y-%m-%d %H:%M:%S'), platform])
        event_id_counter += 1

# Write to CSV
with open('data/raw_events.csv', 'w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(['event_id', 'user_id', 'event_name', 'event_timestamp', 'platform'])
    writer.writerows(rows)

print(f"Successfully generated {len(rows)} event records in data/raw_events.csv")

