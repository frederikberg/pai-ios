import Foundation

/// `GET /api/alarm`: one alarm ringing and two armed, so the screen photographs the pinned
/// ringing row and the list under it.
extension PaiFixtures {

    public static let alarmList = #"""
        {
          "alarms": [
            {
              "id": "a1b2c3d4-0000-4c1a-8f30-2b7e5c918d01", "name": "Alarm",
              "fire_at": "2026-09-01T05:30:00+00:00", "created_at": "2026-08-31T20:12:09.482113+00:00",
              "source": "ios"
            },
            {
              "id": "a1b2c3d4-0000-4c1a-8f30-2b7e5c918d02", "name": "Bahn nach Köln",
              "fire_at": "2026-09-01T06:15:00+00:00", "created_at": "2026-08-31T20:14:51.120344+00:00",
              "source": "watch"
            }
          ],
          "ringing": [
            {
              "id": "a1b2c3d4-0000-4c1a-8f30-2b7e5c918d00", "name": "Wecker",
              "fire_at": "2026-08-31T22:30:00+00:00", "started_at": "2026-08-31T22:30:00.801234+00:00",
              "ends_at": "2026-08-31T22:31:00.801234+00:00"
            }
          ],
          "server_time": "2026-08-31T22:30:12.402188+00:00"
        }
        """#

    /// `POST /api/alarm`.
    public static let alarmCreated = #"""
        {
          "id": "a1b2c3d4-0000-4c1a-8f30-2b7e5c918d03", "name": "Alarm",
          "fire_at": "2026-09-01T07:00:00+00:00", "created_at": "2026-08-31T22:30:20.000001+00:00",
          "source": "ios"
        }
        """#

    /// `GET /api/watch-keys`.
    public static let watchKeys = #"""
        [
          {
            "id": "k1", "name": "fenix 8", "hint": "pw_aB3x",
            "created_at": "2026-08-20T09:00:00.123456+00:00", "last_used_at": "2026-08-31T21:58:00+00:00"
          },
          {
            "id": "k2", "name": "Edge 1040", "hint": "pw_Q7mZ",
            "created_at": "2026-08-25T11:30:00.654321+00:00", "last_used_at": null
          }
        ]
        """#

    /// `POST /api/watch-keys`: the one answer that carries the plain key.
    public static let watchKeyCreated = #"""
        { "id": "k3", "name": "New watch", "key": "pw_fixture-key-not-a-secret-0000000000000000000" }
        """#
}
