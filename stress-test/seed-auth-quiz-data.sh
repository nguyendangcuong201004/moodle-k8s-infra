#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="${NAMESPACE:-moodle}"
MOODLE_CONTAINER="${MOODLE_CONTAINER:-moodle}"
USER_PREFIX="${USER_PREFIX:-user}"
USER_PASSWORD="${USER_PASSWORD:-123456}"
USER_COUNT="${USER_COUNT:-100}"
COURSE_SHORTNAME="${COURSE_SHORTNAME:-TOAN101}"
COURSE_FULLNAME="${COURSE_FULLNAME:-BASIC MATH}"
QUIZ_NAME="${QUIZ_NAME:-BASIC MATH QUIZ}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required"
  exit 1
fi

if ! [[ "${USER_COUNT}" =~ ^[0-9]+$ ]] || (( USER_COUNT <= 0 )); then
  echo "USER_COUNT must be a positive integer"
  exit 1
fi

POD="${MOODLE_POD:-}"
if [[ -z "${POD}" ]]; then
  POD="$(kubectl -n "${NAMESPACE}" get pod -l 'app.kubernetes.io/instance=moodle,app.kubernetes.io/name=moodle,role=web' \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi

if [[ -z "${POD}" ]]; then
  echo "Cannot find Moodle web pod. Set MOODLE_POD explicitly."
  exit 1
fi

echo "Using pod: ${POD}"
echo "Generating ${USER_COUNT} users (${USER_PREFIX}0001...)"

kubectl -n "${NAMESPACE}" exec -i "${POD}" -c "${MOODLE_CONTAINER}" -- sh -c "cat > /tmp/seed_k6_auth_quiz.php" <<'PHP'
<?php
define('CLI_SCRIPT', true);
require('/var/www/html/config.php');
require_once($CFG->dirroot . '/lib/clilib.php');
require_once($CFG->dirroot . '/course/lib.php');
require_once($CFG->dirroot . '/course/modlib.php');
require_once($CFG->dirroot . '/user/lib.php');
require_once($CFG->dirroot . '/mod/quiz/lib.php');
require_once($CFG->dirroot . '/mod/quiz/locallib.php');
require_once($CFG->libdir . '/questionlib.php');
require_once($CFG->libdir . '/moodlelib.php');

[$options] = cli_get_params([
    'userprefix' => 'user',
    'userpassword' => '123456',
    'usercount' => 100,
    'courseshortname' => 'TOAN101',
    'coursefullname' => 'Mon Toan Co Ban',
    'quizname' => 'Quiz Toan Co Ban',
], []);

$userprefix = (string)$options['userprefix'];
$userpassword = (string)$options['userpassword'];
$usercount = (int)$options['usercount'];
$courseshortname = (string)$options['courseshortname'];
$coursefullname = (string)$options['coursefullname'];
$quizname = (string)$options['quizname'];

if ($usercount < 1) {
    fwrite(STDERR, "usercount must be >= 1\n");
    exit(1);
}

echo "STEP=course\n";
$category = \core_course_category::get(1, IGNORE_MISSING);
if (!$category) {
    fwrite(STDERR, "Category ID 1 not found\n");
    exit(1);
}

$course = $DB->get_record('course', ['shortname' => $courseshortname]);
if (!$course) {
    $course = create_course((object)[
        'fullname' => $coursefullname,
        'shortname' => $courseshortname,
        'category' => $category->id,
        'visible' => 1,
    ]);
    echo "Created course: {$course->id}\n";
}

echo "STEP=users\n";
$studentroleid = (int)$DB->get_field('role', 'id', ['shortname' => 'student'], IGNORE_MISSING);
if (!$studentroleid) {
    $studentroleid = 5;
}

for ($i = 1; $i <= $usercount; $i++) {
    $suffix = str_pad((string)$i, 4, '0', STR_PAD_LEFT);
    $username = $userprefix . $suffix;
    $email = $username . '@load.local';

    $user = $DB->get_record('user', ['username' => $username, 'deleted' => 0]);
    if (!$user) {
        $newuser = (object)[
            'auth' => 'manual',
            'confirmed' => 1,
            'username' => $username,
            'password' => hash_internal_user_password($userpassword),
            'firstname' => 'K6',
            'lastname' => "User{$suffix}",
            'email' => $email,
            'mnethostid' => $CFG->mnet_localhost_id,
            'lang' => 'en',
            'maildisplay' => 2,
            'mailformat' => 1,
            'maildigest' => 0,
            'autosubscribe' => 1,
            'trackforums' => 0,
            'timecreated' => time(),
            'timemodified' => time(),
        ];
        $newuser->id = user_create_user($newuser, false, false);
        $user = $newuser;
    } else if (!validate_internal_user_password($user, $userpassword)) {
        update_internal_user_password($user, $userpassword);
    }

    if (!is_enrolled(context_course::instance($course->id), $user->id)) {
        enrol_try_internal_enrol($course->id, $user->id, $studentroleid);
    }
}

echo "STEP=quiz\n";
$quizcm = $DB->get_record_sql("
    SELECT cm.id, cm.instance
      FROM {course_modules} cm
      JOIN {modules} m ON m.id = cm.module
     WHERE cm.course = :courseid
       AND m.name = 'quiz'
     LIMIT 1
", ['courseid' => $course->id]);

if (!$quizcm) {
    // Create quiz directly for load-test purpose to avoid delegated transaction
    // warnings from add_moduleinfo() in read-replica environments.
    $now = time();
    $quizid = $DB->insert_record('quiz', (object)[
        'course' => $course->id,
        'name' => $quizname,
        'intro' => 'Quiz toan co ban (2+2, 3+5...)',
        'introformat' => FORMAT_HTML,
        'timeopen' => 0,
        'timeclose' => 0,
        'timelimit' => 0,
        'overduehandling' => 'autosubmit',
        'graceperiod' => 0,
        'preferredbehaviour' => 'deferredfeedback',
        'canredoquestions' => 0,
        'attempts' => 0,
        'attemptonlast' => 0,
        'grademethod' => 1,
        'decimalpoints' => 2,
        'questiondecimalpoints' => -1,
        'reviewattempt' => 0,
        'reviewcorrectness' => 0,
        'reviewmaxmarks' => 0,
        'reviewmarks' => 0,
        'reviewspecificfeedback' => 0,
        'reviewgeneralfeedback' => 0,
        'reviewrightanswer' => 0,
        'reviewoverallfeedback' => 0,
        'questionsperpage' => 0,
        'navmethod' => 'free',
        'shuffleanswers' => 1,
        'sumgrades' => 0,
        'grade' => 10,
        'timecreated' => $now,
        'timemodified' => $now,
        'password' => '',
        'subnet' => '',
        'browsersecurity' => '-',
        'delay1' => 0,
        'delay2' => 0,
        'showuserpicture' => 0,
        'showblocks' => 0,
        'completionattemptsexhausted' => 0,
        'completionminattempts' => 0,
        'allowofflineattempts' => 0,
        'precreateattempts' => 0,
    ]);

    // Same as quiz_add_instance(): without a row in quiz_sections, new attempts get an empty
    // layout string and attempt.php throws "No questions found" even when quiz_slots exist.
    $DB->insert_record('quiz_sections', (object)[
        'quizid' => $quizid,
        'firstslot' => 1,
        'heading' => '',
        'shufflequestions' => 0,
    ]);

    $section = $DB->get_record('course_sections', ['course' => $course->id, 'section' => 0], '*', MUST_EXIST);
    $moduleid = $DB->get_field('modules', 'id', ['name' => 'quiz'], MUST_EXIST);
    $cmid = $DB->insert_record('course_modules', (object)[
        'course' => $course->id,
        'module' => $moduleid,
        'instance' => $quizid,
        'section' => $section->id,
        'idnumber' => '',
        'added' => $now,
        'score' => 0,
        'indent' => 0,
        'visible' => 1,
        'visibleoncoursepage' => 1,
        'visibleold' => 1,
        'groupmode' => 0,
        'groupingid' => 0,
        'completion' => 0,
        'completiongradeitemnumber' => null,
        'completionview' => 0,
        'completionexpected' => 0,
        'showdescription' => 0,
        'availability' => null,
        'deletioninprogress' => 0,
        'downloadcontent' => 1,
        'lang' => '',
    ]);
    $sequence = trim((string)$section->sequence);
    $newsequence = $sequence === '' ? (string)$cmid : ($sequence . ',' . $cmid);
    $DB->set_field('course_sections', 'sequence', $newsequence, ['id' => $section->id]);

    $quizcm = (object)['id' => $cmid, 'instance' => $quizid];
    echo "Created quiz cmid: {$quizcm->id}\n";
}

echo "STEP=questions\n";
$quiz = $DB->get_record('quiz', ['id' => $quizcm->instance], '*', MUST_EXIST);
if (!$DB->record_exists('quiz_sections', ['quizid' => $quiz->id])) {
    $DB->insert_record('quiz_sections', (object)[
        'quizid' => $quiz->id,
        'firstslot' => 1,
        'heading' => '',
        'shufflequestions' => 0,
    ]);
    echo "REPAIR=quiz_sections\n";
}
$existingslots = (int)$DB->count_records('quiz_slots', ['quizid' => $quiz->id]);
if ($existingslots === 0) {
    $coursecontext = context_course::instance($course->id);
    $qcat = $DB->get_record('question_categories', [
        'contextid' => $coursecontext->id,
        'name' => 'Load test questions',
    ]);
    if (!$qcat) {
        $qcatid = $DB->insert_record('question_categories', (object)[
            'name' => 'Load test questions',
            'contextid' => $coursecontext->id,
            'info' => 'Auto-generated for k6 load test',
            'infoformat' => FORMAT_PLAIN,
            'stamp' => substr(md5((string)microtime(true)), 0, 12),
            'parent' => 0,
            'sortorder' => 999,
            'idnumber' => null,
        ]);
        $qcat = $DB->get_record('question_categories', ['id' => $qcatid], '*', MUST_EXIST);
    }

    $seedquestions = [
        ['name' => '1 + 1 = ?', 'prompt' => '1+1=?', 'answer' => '2'],
        ['name' => '2 + 2 = ?', 'prompt' => '2+2=?', 'answer' => '4'],
        ['name' => '3 + 5 = ?', 'prompt' => '3+5=?', 'answer' => '8'],
    ];

    $added = 0;
    foreach ($seedquestions as $sq) {
        $now = time();
        $questionid = $DB->insert_record('question', (object)[
            'parent' => 0,
            'name' => $sq['name'],
            'questiontext' => $sq['prompt'],
            'questiontextformat' => FORMAT_HTML,
            'generalfeedback' => '',
            'generalfeedbackformat' => FORMAT_HTML,
            'defaultmark' => 1,
            'penalty' => 0.3333333,
            'qtype' => 'shortanswer',
            'length' => 1,
            'stamp' => md5(uniqid((string)$now, true)),
            'timecreated' => $now,
            'timemodified' => $now,
            'createdby' => null,
            'modifiedby' => null,
        ]);

        $DB->insert_record('qtype_shortanswer_options', (object)[
            'questionid' => $questionid,
            'usecase' => 0,
        ]);
        $DB->insert_record('question_answers', (object)[
            'question' => $questionid,
            'answer' => $sq['answer'],
            'answerformat' => FORMAT_PLAIN,
            'fraction' => 1,
            'feedback' => '',
            'feedbackformat' => FORMAT_HTML,
        ]);
        // Wildcard for other answers.
        $DB->insert_record('question_answers', (object)[
            'question' => $questionid,
            'answer' => '*',
            'answerformat' => FORMAT_PLAIN,
            'fraction' => 0,
            'feedback' => '',
            'feedbackformat' => FORMAT_HTML,
        ]);

        $qbeid = $DB->insert_record('question_bank_entries', (object)[
            'questioncategoryid' => $qcat->id,
            'idnumber' => null,
            'ownerid' => null,
        ]);
        $DB->insert_record('question_versions', (object)[
            'questionbankentryid' => $qbeid,
            'version' => 1,
            'questionid' => $questionid,
            'status' => 'ready',
        ]);

        quiz_add_quiz_question($questionid, $quiz, 0, 1.0);
        $added++;
    }
    echo "QUESTIONS_ADDED={$added}\n";
} else {
    echo "QUESTIONS_ADDED=0 (quiz already has {$existingslots} slot(s))\n";
}

// Moodle 4.2+: deprecated quiz_update_sumgrades() is a no-op. Slots can have maxmark
// but quiz.sumgrades stays 0 -> "Cannot start an attempt" (cannotstartgradesmismatch).
$quiz = $DB->get_record('quiz', ['id' => $quiz->id], '*', MUST_EXIST);
\mod_quiz\quiz_settings::create((int) $quiz->id)->get_grade_calculator()->recompute_quiz_sumgrades();
$quiz = $DB->get_record('quiz', ['id' => $quiz->id], '*', MUST_EXIST);
echo "QUIZ_SUMGRADES={$quiz->sumgrades} QUIZ_OUT_OF={$quiz->grade}\n";

// One page per attempt (0 = unlimited) so k6 can submit all short answers in one POST.
$DB->set_field('quiz', 'questionsperpage', 0, ['id' => $quiz->id]);
quiz_repaginate_questions($quiz->id, 0);
echo "QUIZ_REPAGINATED=1\n";

echo "COURSE_ID={$course->id}\n";
echo "QUIZ_CMID=" . ($quizcm ? $quizcm->id : '') . "\n";
$firstusername = $userprefix . str_pad('1', 4, '0', STR_PAD_LEFT);
$reason = '';
$ok = authenticate_user_login($firstusername, $userpassword, false, $reason, false);
echo "LOGIN_TEST=" . ($ok ? 'ok' : 'fail') . "\n";
echo "LOGIN_TEST_USER={$firstusername}\n";
PHP

set +e
SEED_OUTPUT="$(
  kubectl -n "${NAMESPACE}" exec "${POD}" -c "${MOODLE_CONTAINER}" -- \
    runuser -u www-data -- php /tmp/seed_k6_auth_quiz.php \
      --userprefix="${USER_PREFIX}" \
      --userpassword="${USER_PASSWORD}" \
      --usercount="${USER_COUNT}" \
      --courseshortname="${COURSE_SHORTNAME}" \
      --coursefullname="${COURSE_FULLNAME}" \
      --quizname="${QUIZ_NAME}" 2>&1
)"
SEED_RC=$?
set -e

if [[ ${SEED_RC} -ne 0 ]]; then
  echo "${SEED_OUTPUT}"
  echo "Seed failed with exit code ${SEED_RC}."
  exit ${SEED_RC}
fi

echo "${SEED_OUTPUT}"

COURSE_ID="$(printf '%s\n' "${SEED_OUTPUT}" | awk -F= '/^COURSE_ID=/{print $2}' | tail -n 1)"
QUIZ_CMID="$(printf '%s\n' "${SEED_OUTPUT}" | awk -F= '/^QUIZ_CMID=/{print $2}' | tail -n 1)"
LOGIN_TEST="$(printf '%s\n' "${SEED_OUTPUT}" | awk -F= '/^LOGIN_TEST=/{print $2}' | tail -n 1)"

if [[ -z "${COURSE_ID}" || -z "${QUIZ_CMID}" ]]; then
  echo "Seed failed: COURSE_ID/QUIZ_CMID not found in output."
  exit 1
fi

if [[ "${LOGIN_TEST}" != "ok" ]]; then
  echo "Seed failed: LOGIN_TEST is not ok."
  exit 1
fi

echo "Done."
echo "Run k6 with:"
echo "  PROFILE=auth_quiz QUIZ_PATH=/mod/quiz/view.php?id=${QUIZ_CMID} AUTH_USER_PREFIX=${USER_PREFIX} AUTH_USER_COUNT=${USER_COUNT} AUTH_USER_PASSWORD=${USER_PASSWORD} ./run-stress-test.sh"
