#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="${NAMESPACE:-moodle}"
MOODLE_CONTAINER="${MOODLE_CONTAINER:-moodle}"
USER_PREFIX="${USER_PREFIX:-user}"
USER_PASSWORD="${USER_PASSWORD:-123456}"
USER_COUNT="${USER_COUNT:-500}"
TEACHER_PREFIX="${TEACHER_PREFIX:-teacher}"
TEACHER_PASSWORD="${TEACHER_PASSWORD:-123456}"
TEACHER_COUNT="${TEACHER_COUNT:-100}"
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

# Auto-detect KUBECONFIG from repo if not already set
if [[ -z "${KUBECONFIG:-}" ]]; then
  ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
  for _kc in \
    "${ROOT_DIR}/digitalocean/kubeconfig-production" \
    "${ROOT_DIR}/digitalocean/kubeconfig-staging" \
    "${ROOT_DIR}/digitalocean/kubeconfig"; do
    if [[ -f "${_kc}" ]]; then
      export KUBECONFIG="${_kc}"
      echo "Auto-detected KUBECONFIG=${KUBECONFIG}"
      break
    fi
  done
fi

POD="${MOODLE_POD:-}"
if [[ -z "${POD}" ]]; then
  POD="$(kubectl -n "${NAMESPACE}" get pod -l 'app.kubernetes.io/instance=moodle,app.kubernetes.io/name=moodle,role=web' \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi

if [[ -z "${POD}" ]]; then
  echo "Cannot find Moodle web pod. Set MOODLE_POD explicitly or export KUBECONFIG."
  exit 1
fi

echo "Using pod: ${POD}"
echo "Generating ${USER_COUNT} students (${USER_PREFIX}0001…) and ${TEACHER_COUNT} teachers (${TEACHER_PREFIX}0001…)"

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
require_once($CFG->libdir . '/gradelib.php');
require_once($CFG->libdir . '/grade/grade_category.php');

// Load-test seed data must not depend on an SMTP/sendmail agent in the PHP image.
// Some Moodle APIs can emit enrolment/course-module notifications inside DB transactions;
// if PHP cannot instantiate mail, the transaction is left aborted and later APIs fail.
$CFG->noemailever = true;
$CFG->sendmail = '/bin/true';
set_config('noemailever', 1);
set_config('sendmail', '/bin/true');
\core\session\manager::set_user(get_admin());

[$options] = cli_get_params([
    'userprefix' => 'user',
    'userpassword' => '123456',
    'usercount' => 100,
    'teacherprefix' => 'teacher',
    'teacherpassword' => '123456',
    'teachercount' => 10,
    'courseshortname' => 'TOAN101',
    'coursefullname' => 'Mon Toan Co Ban',
    'quizname' => 'Quiz Toan Co Ban',
], []);

$userprefix = (string)$options['userprefix'];
$userpassword = (string)$options['userpassword'];
$usercount = (int)$options['usercount'];
$teacherprefix = (string)$options['teacherprefix'];
$teacherpassword = (string)$options['teacherpassword'];
$teachercount = (int)$options['teachercount'];
$courseshortname = (string)$options['courseshortname'];
$coursefullname = (string)$options['coursefullname'];
$quizname = (string)$options['quizname'];

function k6_quiz_defaults(stdClass $quiz): stdClass {
    $quiz->intro = $quiz->intro ?? 'Quiz toan co ban (2+2, 3+5...)';
    $quiz->introformat = $quiz->introformat ?? FORMAT_HTML;
    $quiz->timeopen = $quiz->timeopen ?? 0;
    $quiz->timeclose = $quiz->timeclose ?? 0;
    $quiz->timelimit = $quiz->timelimit ?? 0;
    $quiz->overduehandling = $quiz->overduehandling ?? 'autosubmit';
    $quiz->graceperiod = $quiz->graceperiod ?? 0;
    $quiz->preferredbehaviour = $quiz->preferredbehaviour ?? 'deferredfeedback';
    $quiz->canredoquestions = $quiz->canredoquestions ?? 0;
    $quiz->attempts = $quiz->attempts ?? 0;
    $quiz->attemptonlast = $quiz->attemptonlast ?? 0;
    $quiz->grademethod = $quiz->grademethod ?? QUIZ_GRADEHIGHEST;
    $quiz->decimalpoints = $quiz->decimalpoints ?? 2;
    $quiz->questiondecimalpoints = $quiz->questiondecimalpoints ?? -1;
    $quiz->reviewattempt = $quiz->reviewattempt ?? 0;
    $quiz->reviewcorrectness = $quiz->reviewcorrectness ?? 0;
    $quiz->reviewmaxmarks = $quiz->reviewmaxmarks ?? 0;
    $quiz->reviewmarks = $quiz->reviewmarks ?? 0;
    $quiz->reviewspecificfeedback = $quiz->reviewspecificfeedback ?? 0;
    $quiz->reviewgeneralfeedback = $quiz->reviewgeneralfeedback ?? 0;
    $quiz->reviewrightanswer = $quiz->reviewrightanswer ?? 0;
    $quiz->reviewoverallfeedback = $quiz->reviewoverallfeedback ?? 0;
    $quiz->questionsperpage = $quiz->questionsperpage ?? 0;
    $quiz->navmethod = $quiz->navmethod ?? QUIZ_NAVMETHOD_FREE;
    $quiz->shuffleanswers = $quiz->shuffleanswers ?? 1;
    $quiz->sumgrades = $quiz->sumgrades ?? 0;
    $quiz->grade = $quiz->grade ?? 10;
    $quiz->password = $quiz->password ?? '';
    $quiz->quizpassword = $quiz->quizpassword ?? $quiz->password;
    $quiz->subnet = $quiz->subnet ?? '';
    $quiz->browsersecurity = $quiz->browsersecurity ?? '-';
    $quiz->delay1 = $quiz->delay1 ?? 0;
    $quiz->delay2 = $quiz->delay2 ?? 0;
    $quiz->showuserpicture = $quiz->showuserpicture ?? 0;
    $quiz->showblocks = $quiz->showblocks ?? 0;
    $quiz->completionattemptsexhausted = $quiz->completionattemptsexhausted ?? 0;
    $quiz->completionminattempts = $quiz->completionminattempts ?? 0;
    $quiz->allowofflineattempts = $quiz->allowofflineattempts ?? 0;
    $quiz->precreateattempts = $quiz->precreateattempts ?? 0;
    $quiz->feedbackboundarycount = $quiz->feedbackboundarycount ?? 0;
    $quiz->feedbacktext = $quiz->feedbacktext ?? [
        ['text' => '', 'format' => FORMAT_HTML, 'itemid' => 0],
    ];
    $quiz->feedbackboundaries = $quiz->feedbackboundaries ?? [0 => ''];
    return $quiz;
}

function repair_course_gradebook_for_k6(int $courseid): void {
    global $DB;

    $rootcats = array_values($DB->get_records('grade_categories', [
        'courseid' => $courseid,
        'parent' => null,
    ], 'id ASC'));

    if (count($rootcats) > 1) {
        $keepcat = $rootcats[0];
        for ($i = 1; $i < count($rootcats); $i++) {
            $cat = $rootcats[$i];
            $DB->delete_records('grade_grades', [
                'itemid' => $DB->get_field('grade_items', 'id', [
                    'courseid' => $courseid,
                    'itemtype' => 'course',
                    'iteminstance' => $cat->id,
                ], IGNORE_MISSING),
            ]);
            $DB->delete_records('grade_items', [
                'courseid' => $courseid,
                'itemtype' => 'course',
                'iteminstance' => $cat->id,
            ]);
            $DB->delete_records('grade_categories', ['id' => $cat->id]);
            echo "REPAIR=deleted_duplicate_grade_category:{$cat->id}\n";
        }

        $courseitems = array_values($DB->get_records('grade_items', [
            'courseid' => $courseid,
            'itemtype' => 'course',
        ], 'id ASC'));
        if (count($courseitems) > 1) {
            $keepitem = null;
            foreach ($courseitems as $item) {
                if ((int)$item->iteminstance === (int)$keepcat->id) {
                    $keepitem = $item;
                    break;
                }
            }
            $keepitem = $keepitem ?: $courseitems[0];
            foreach ($courseitems as $item) {
                if ((int)$item->id === (int)$keepitem->id) {
                    continue;
                }
                $DB->delete_records('grade_grades', ['itemid' => $item->id]);
                $DB->delete_records('grade_items', ['id' => $item->id]);
                echo "REPAIR=deleted_duplicate_course_grade_item:{$item->id}\n";
            }
            if ((int)$keepitem->iteminstance !== (int)$keepcat->id) {
                $DB->set_field('grade_items', 'iteminstance', $keepcat->id, ['id' => $keepitem->id]);
            }
        }
    }

    grade_category::fetch_course_category($courseid);
}

if ($usercount < 1) {
    fwrite(STDERR, "usercount must be >= 1\n");
    exit(1);
}

if ($teachercount < 1) {
    fwrite(STDERR, "teachercount must be >= 1\n");
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
repair_course_gradebook_for_k6((int)$course->id);

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

echo "STEP=teachers\n";
$teacherroleid = (int)$DB->get_field('role', 'id', ['shortname' => 'editingteacher'], IGNORE_MISSING);
if (!$teacherroleid) {
    $teacherroleid = 3;
}

for ($i = 1; $i <= $teachercount; $i++) {
    $suffix = str_pad((string)$i, 4, '0', STR_PAD_LEFT);
    $username = $teacherprefix . $suffix;
    $email = $username . '@load.local';

    $user = $DB->get_record('user', ['username' => $username, 'deleted' => 0]);
    if (!$user) {
        $newuser = (object)[
            'auth' => 'manual',
            'confirmed' => 1,
            'username' => $username,
            'password' => hash_internal_user_password($teacherpassword),
            'firstname' => 'K6',
            'lastname' => "Teacher{$suffix}",
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
    } else if (!validate_internal_user_password($user, $teacherpassword)) {
        update_internal_user_password($user, $teacherpassword);
    }

    if (!is_enrolled(context_course::instance($course->id), $user->id)) {
        enrol_try_internal_enrol($course->id, $user->id, $teacherroleid);
    }
}

echo "STEP=quiz\n";
$stalequizcms = $DB->get_records_sql("
    SELECT cm.id, cm.instance, q.name
      FROM {course_modules} cm
      JOIN {modules} m ON m.id = cm.module
 LEFT JOIN {quiz} q ON q.id = cm.instance
     WHERE cm.course = :courseid
       AND m.name = 'quiz'
       AND (q.id IS NULL OR q.name <> :quizname)
     ORDER BY cm.id ASC
", ['courseid' => $course->id, 'quizname' => $quizname]);
foreach ($stalequizcms as $stalequizcm) {
    course_delete_module((int)$stalequizcm->id);
    echo "REPAIR=deleted_stale_quiz_cmid:{$stalequizcm->id}\n";
}

$quizcm = $DB->get_record_sql("
    SELECT cm.id, cm.instance
      FROM {course_modules} cm
      JOIN {modules} m ON m.id = cm.module
      JOIN {quiz} q ON q.id = cm.instance
     WHERE cm.course = :courseid
       AND m.name = 'quiz'
       AND q.name = :quizname
     ORDER BY cm.id ASC
     LIMIT 1
", ['courseid' => $course->id, 'quizname' => $quizname]);

if (!$quizcm) {
    $moduleid = $DB->get_field('modules', 'id', ['name' => 'quiz'], MUST_EXIST);
    $moduleinfo = k6_quiz_defaults((object)[
        'modulename' => 'quiz',
        'module' => $moduleid,
        'section' => 0,
        'name' => $quizname,
        'visible' => 1,
        'visibleoncoursepage' => 1,
        'groupmode' => 0,
        'groupingid' => 0,
        'cmidnumber' => '',
        'completion' => 0,
        'completionpassgrade' => 0,
        'completiongradeitemnumber' => null,
        'completionview' => 0,
        'completionexpected' => 0,
        'showdescription' => 0,
        'downloadcontent' => 1,
        'availabilityconditionsjson' => '',
        'lang' => '',
    ]);
    $created = add_moduleinfo($moduleinfo, $course);
    $quizcm = (object)['id' => $created->coursemodule, 'instance' => $created->instance];
    echo "Created quiz cmid: {$quizcm->id}\n";
}

echo "STEP=questions\n";
$quiz = $DB->get_record('quiz', ['id' => $quizcm->instance], '*', MUST_EXIST);
$quiz->coursemodule = $quizcm->id;
$quiz = k6_quiz_defaults($quiz);
quiz_grade_item_update($quiz);
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
$firstteacher = $teacherprefix . str_pad('1', 4, '0', STR_PAD_LEFT);
$treason = '';
$tok = authenticate_user_login($firstteacher, $teacherpassword, false, $treason, false);
echo "TEACHER_LOGIN_TEST=" . ($tok ? 'ok' : 'fail') . "\n";
echo "TEACHER_LOGIN_TEST_USER={$firstteacher}\n";
PHP

set +e
SEED_OUTPUT="$(
  kubectl -n "${NAMESPACE}" exec "${POD}" -c "${MOODLE_CONTAINER}" -- \
    runuser -u www-data -- php /tmp/seed_k6_auth_quiz.php \
      --userprefix="${USER_PREFIX}" \
      --userpassword="${USER_PASSWORD}" \
      --usercount="${USER_COUNT}" \
      --teacherprefix="${TEACHER_PREFIX}" \
      --teacherpassword="${TEACHER_PASSWORD}" \
      --teachercount="${TEACHER_COUNT}" \
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
TEACHER_LOGIN_TEST="$(printf '%s\n' "${SEED_OUTPUT}" | awk -F= '/^TEACHER_LOGIN_TEST=/{print $2}' | tail -n 1)"

if [[ -z "${COURSE_ID}" || -z "${QUIZ_CMID}" ]]; then
  echo "Seed failed: COURSE_ID/QUIZ_CMID not found in output."
  exit 1
fi

if [[ "${LOGIN_TEST}" != "ok" ]]; then
  echo "Seed failed: LOGIN_TEST is not ok."
  exit 1
fi

if [[ "${TEACHER_LOGIN_TEST}" != "ok" ]]; then
  echo "Seed failed: TEACHER_LOGIN_TEST is not ok."
  exit 1
fi

echo "Done."
echo "Run k6 (students only):"
echo "  PROFILE=auth_quiz QUIZ_PATH=/mod/quiz/view.php?id=${QUIZ_CMID} AUTH_USER_PREFIX=${USER_PREFIX} AUTH_USER_COUNT=${USER_COUNT} AUTH_USER_PASSWORD=${USER_PASSWORD} ./0_stress_testing.sh"
echo ""
echo "Run k6 (mixed students + teachers):"
echo "  PROFILE=mixed_roles QUIZ_PATH=/mod/quiz/view.php?id=${QUIZ_CMID} COURSE_PATH=/course/view.php?id=${COURSE_ID} AUTH_USER_PREFIX=${USER_PREFIX} AUTH_USER_COUNT=${USER_COUNT} AUTH_USER_PASSWORD=${USER_PASSWORD} TEACHER_USER_PREFIX=${TEACHER_PREFIX} TEACHER_USER_COUNT=${TEACHER_COUNT} TEACHER_USER_PASSWORD=${TEACHER_PASSWORD} TEACHER_RATIO_PCT=20 ./0_stress_testing.sh"
