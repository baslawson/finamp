/// Broad local listening hours, including one band across midnight.
enum ListeningHour { night, morning, daytime, evening }

ListeningHour listeningHour(int hour) {
  if (hour < 5 || hour >= 22) return ListeningHour.night;
  if (hour < 9) return ListeningHour.morning;
  if (hour < 17) return ListeningHour.daytime;
  return ListeningHour.evening;
}
